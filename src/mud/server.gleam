import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import glisten.{type Connection}
import glisten/socket
import glisten/socket/options
import mud/id.{type RoomId}
import mud/player
import mud/session
import mud/world

pub fn start(world: Subject(world.Message), entrance: RoomId, port: Int) {
  let assert Ok(_) =
    glisten.new(on_init(world, entrance), loop)
    |> glisten.with_active_state(options.Once)
    |> glisten.with_pool_size(4)
    |> glisten.with_close(on_close)
    |> glisten.start(port)
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
    [session.Join(session, room), ..rest] ->
      case world.join(state.world, session, room) {
        Ok(_) -> run_effects(state, conn, rest)
        Error(_) -> {
          let #(state, effects) = session.join_failed(state)
          case run_effects(state, conn, effects) {
            Ok(state) -> run_effects(state, conn, rest)
            Error(e) -> Error(e)
          }
        }
      }
    [session.Do(action), ..rest] ->
      case run_effect(state, conn, action) {
        Ok(_) -> run_effects(state, conn, rest)
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
      world.say(state.world, player.id, line)
      Ok(state)
    }
    player.Move(dir), _, Some(player) -> {
      world.move(state.world, player.id, dir)
      Ok(state)
    }
    player.Look, _, Some(player) -> {
      world.look(state.world, player.id)
      Ok(state)
    }
    player.Leave, _, Some(player) -> {
      world.leave(state.world, player.id)
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
    session.InGame(player) -> Some(player)
  }
}
