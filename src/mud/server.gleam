import gleam/bytes_tree
import gleam/erlang/process
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/string
import glisten.{type Connection}
import glisten/socket
import glisten/socket/options
import mud/id.{type RoomId}
import mud/player
import mud/room
import mud/session
import mud/world

pub fn server_child(
  world: process.Name(world.Message),
  entrance: RoomId,
  port: Int,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  glisten.new(on_init(world, entrance), loop)
  |> glisten.with_active_state(options.Once)
  |> glisten.with_pool_size(4)
  |> glisten.with_close(on_close)
  |> glisten.supervised(port)
}

pub fn on_init(world: process.Name(world.Message), entrance: RoomId) {
  fn(conn: Connection(session.Message)) -> #(
    session.State,
    Option(process.Selector(session.Message)),
  ) {
    let subject = process.new_subject()
    let replies = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(replies, session.WorldMessage)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(_, pid, _) -> session.RoomDown(Some(pid))
          // never happens, we don't monitor ports
          process.PortDown(..) -> session.RoomDown(None)
        }
      })
    let #(state, effects) = session.started(subject, replies, world, entrance)
    case run_effects(state, Some(conn), effects) {
      Ok(state) -> #(state, Some(selector))
      Error(_) -> #(state, None)
    }
  }
}

fn loop(
  state: session.State,
  msg: glisten.Message(session.Message),
  conn: Connection(session.Message),
) -> glisten.Next(session.State, glisten.Message(session.Message)) {
  let #(state, effects) = case msg {
    glisten.Packet(chunk) -> session.receive_bytes(state, chunk)
    glisten.User(user_message) -> session.receive_message(state, user_message)
  }
  case run_effects(state, Some(conn), effects) {
    Ok(state) -> glisten.continue(state)
    Error(_) -> glisten.stop()
  }
}

fn on_close(state: session.State) {
  let _ =
    session.closed(state)
    |> run_effects(state, None, _)
  Nil
}

type StopReason {
  SendFailed(socket.SocketReason)
  Requested
}

fn run_effects(
  state: session.State,
  conn: Option(Connection(session.Message)),
  effects: List(session.Effect),
) -> Result(session.State, StopReason) {
  case effects {
    [] -> Ok(state)
    [session.Stop, ..] -> Error(Requested)
    [session.Join(to_room_id), ..rest] ->
      case state.status {
        session.Joining(player_id, _player_name) -> {
          world.join(
            state.world,
            player_id,
            process.self(),
            to_room_id,
            state.replies,
          )
          let _ = process.send_after(state.subject, 5000, session.JoinTimeout)
          run_effects(state, conn, rest)
        }
        // A join request is only meaningful while a name is being claimed.
        session.AwaitingName | session.InGame(_) -> {
          skip_effect("a join request outside the Joining state")
          run_effects(state, conn, rest)
        }
      }
    [session.EnterRoom(to_room, attempt), ..rest] ->
      case state.status, process.named(to_room.process_name) {
        session.InGame(player), Ok(pid) -> {
          case state.room_watch {
            Some(session.RoomWatch(_pid, monitor)) ->
              process.demonitor_process(monitor)
            None -> Nil
          }
          room.enter(
            to_room.process_name,
            session.to_session(state.subject, player),
          )
          let room_watch =
            Some(session.RoomWatch(pid: pid, monitor: process.monitor(pid)))
          run_effects(session.State(..state, room_watch:), conn, rest)
        }
        session.InGame(_), Error(_) -> {
          let _ =
            process.send_after(
              state.subject,
              100,
              session.RetryEnter(to_room, attempt + 1),
            )
          run_effects(state, conn, rest)
        }
        _, _ -> run_effects(state, conn, rest)
      }
    [session.LeaveRoom(room_name), ..rest] ->
      case state.status {
        session.InGame(player_state) -> {
          room.leave(room_name, player_state.id)
          run_effects(state, conn, rest)
        }
        _ -> run_effects(state, conn, rest)
      }
    [session.Do(action), ..rest] ->
      case run_effect(state, conn, action) {
        Ok(new_state) -> run_effects(new_state, conn, rest)
        Error(e) -> Error(e)
      }
  }
}

fn run_effect(
  state: session.State,
  conn: Option(Connection(session.Message)),
  action: player.Action,
) -> Result(session.State, StopReason) {
  case action {
    player.Output(text) -> write(state, conn, text)
    player.Say(line) ->
      with_player(state, action, fn(player) {
        room.say(player.room.process_name, player.id, line)
        Ok(state)
      })
    player.Move(dir) ->
      with_player(state, action, fn(player) {
        case world.move(state.world, player.room.id, dir, state.replies) {
          Ok(_) -> Ok(state)
          Error(_) -> write(state, conn, "The world is restarting, try again.")
        }
      })
    player.Look ->
      with_player(state, action, fn(player) {
        room.look(player.room.process_name, player.id)
        Ok(state)
      })
  }
}

fn with_player(
  state: session.State,
  action: player.Action,
  perform: fn(player.State) -> Result(session.State, StopReason),
) -> Result(session.State, StopReason) {
  case current_player(state) {
    Some(player) -> perform(player)
    None -> skip_playerless_effect(state, action)
  }
}

// An effect that needs a player was produced for a session that is not in the game.
fn skip_playerless_effect(
  state: session.State,
  action: player.Action,
) -> Result(session.State, StopReason) {
  skip_effect(string.inspect(action) <> " with no player in the session")
  Ok(state)
}

fn skip_effect(reason: String) -> Nil {
  // TODO: replace with the `logging` package
  io.println_error("skipping " <> reason)
}

fn write(
  state: session.State,
  conn: Option(Connection(session.Message)),
  text: String,
) -> Result(session.State, StopReason) {
  case conn {
    Some(conn) ->
      case glisten.send(conn, bytes_tree.from_string(text <> "\n")) {
        Ok(_) -> Ok(state)
        Error(e) -> Error(SendFailed(e))
      }
    // The client is gone (on_close): there is nobody left to write to, and that
    // is not an error.
    None -> Ok(state)
  }
}

fn current_player(state: session.State) -> Option(player.State) {
  case state.status {
    session.AwaitingName -> None
    session.Joining(_, _) -> None
    session.InGame(player) -> Some(player)
  }
}
