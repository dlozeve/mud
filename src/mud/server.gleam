import gleam/bytes_tree
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import glisten.{type Connection}
import glisten/socket
import glisten/socket/options
import mud/room
import mud/runner
import mud/session
import mud/world

pub fn server_child(
  world: process.Name(world.Message),
  entrance: room.Id,
  port: Int,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  glisten.new(on_init(world, entrance), loop)
  |> glisten.with_active_state(options.Once)
  |> glisten.with_pool_size(4)
  |> glisten.with_close(on_close)
  |> glisten.supervised(port)
}

pub fn on_init(world: process.Name(world.Message), entrance: room.Id) {
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
    case runner.run_effects(state, sender(Some(conn)), effects) {
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
  case runner.run_effects(state, sender(Some(conn)), effects) {
    Ok(state) -> glisten.continue(state)
    Error(_) -> glisten.stop()
  }
}

fn on_close(state: session.State) {
  let _ =
    session.closed(state)
    |> runner.run_effects(state, sender(None), _)
  Nil
}

fn sender(
  conn: Option(Connection(session.Message)),
) -> runner.Sender(socket.SocketReason) {
  fn(text) {
    case conn {
      Some(conn) -> glisten.send(conn, bytes_tree.from_string(text))
      // The client is gone (on_close): there is nobody left to write to, and
      // that is not an error.
      None -> Ok(Nil)
    }
  }
}
