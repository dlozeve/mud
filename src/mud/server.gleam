import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import glisten.{type Connection}
import glisten/socket
import glisten/socket/options
import mud/id.{type RoomId}
import mud/player
import mud/room
import mud/session
import mud/world

pub fn server_child(
  world: Subject(world.Message),
  entrance: RoomId,
  port: Int,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  glisten.new(on_init(world, entrance), loop)
  |> glisten.with_active_state(options.Once)
  |> glisten.with_pool_size(4)
  |> glisten.with_close(on_close)
  |> glisten.supervised(port)
}

pub fn on_init(world: Subject(world.Message), entrance: RoomId) {
  fn(conn: Connection(player.Message)) -> #(
    session.State,
    Option(process.Selector(player.Message)),
  ) {
    let subject = process.new_subject()
    let selector = process.new_selector() |> process.select(subject)
    let #(state, effects) = session.started(subject, world, entrance)
    case run_effects(state, Some(conn), effects) {
      Ok(state) -> #(state, Some(selector))
      Error(_) -> #(state, None)
    }
  }
}

fn loop(
  state: session.State,
  msg: glisten.Message(player.Message),
  conn: Connection(player.Message),
) -> glisten.Next(session.State, glisten.Message(player.Message)) {
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
  Unexpected
}

fn run_effects(
  state: session.State,
  conn: Option(Connection(player.Message)),
  effects: List(session.Effect),
) -> Result(session.State, StopReason) {
  case effects {
    [] -> Ok(state)
    [session.Stop, ..] -> Error(Requested)
    [session.Join(to_room_id), ..rest] ->
      case world.join(state.world, to_room_id) {
        Ok(to_room) ->
          case state.status {
            session.Joining(player_id, player_name) -> {
              let player =
                player.State(
                  id: player_id,
                  name: player_name,
                  world: state.world,
                  room: to_room,
                )
              room.enter(
                to_room.process_name,
                player.to_session(state.subject, player),
              )
              room.look(to_room.process_name, player.id)
              Ok(session.State(..state, status: session.InGame(player)))
            }
            session.AwaitingName -> Error(Unexpected)
            session.InGame(_) -> Error(Unexpected)
          }
        Error(e) -> {
          let #(state, effects) = session.join_failed(state, e)
          case run_effects(state, conn, effects) {
            Ok(state) -> run_effects(state, conn, rest)
            Error(e) -> Error(e)
          }
        }
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
  conn: Option(Connection(player.Message)),
  action: player.Action,
) -> Result(session.State, StopReason) {
  case action, conn, current_player(state) {
    player.Output(text), Some(conn), _ ->
      case glisten.send(conn, bytes_tree.from_string(text <> "\n")) {
        Ok(_) -> Ok(state)
        Error(e) -> Error(SendFailed(e))
      }
    player.Say(line), _, Some(player) -> {
      room.say(player.room.process_name, player.id, line)
      Ok(state)
    }
    player.Move(dir), Some(conn), Some(player) ->
      case world.move(state.world, player.room.id, dir) {
        Ok(to_room) -> {
          room.leave(player.room.process_name, player.id)
          room.enter(
            to_room.process_name,
            player.to_session(state.subject, player),
          )
          room.look(player.room.process_name, player.id)
          Ok(with_player(state, fn(p) { player.State(..p, room: to_room) }))
        }
        Error(_) ->
          case
            glisten.send(
              conn,
              bytes_tree.from_string("You can't go that way.\n"),
            )
          {
            Ok(_) -> Ok(state)
            Error(e) -> Error(SendFailed(e))
          }
      }
    player.Look, _, Some(player) -> {
      room.look(player.room.process_name, player.id)
      Ok(state)
    }
    player.Leave, _, Some(player) -> {
      room.leave(player.room.process_name, player.id)
      Ok(state)
    }
    player.Unknown(line), Some(conn), _ ->
      case
        glisten.send(conn, bytes_tree.from_string("Unknown command: " <> line))
      {
        Ok(_) -> Ok(state)
        Error(e) -> Error(SendFailed(e))
      }
    _, _, _ -> Error(Unexpected)
  }
}

fn current_player(state: session.State) -> Option(player.State) {
  case state.status {
    session.AwaitingName -> None
    session.Joining(_, _) -> None
    session.InGame(player) -> Some(player)
  }
}

fn with_player(
  state: session.State,
  update: fn(player.State) -> player.State,
) -> session.State {
  case state.status {
    session.AwaitingName -> state
    session.Joining(_, _) -> state
    session.InGame(player) ->
      session.State(..state, status: session.InGame(update(player)))
  }
}
