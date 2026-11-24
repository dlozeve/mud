import gleam/bytes_tree
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/string
import glisten.{type Connection}
import glisten/internal/listener
import glisten/socket
import glisten/socket/options
import mud/room
import mud/runner
import mud/session
import mud/world
import woof

// The listener is named explicitly so that callers can ask the OS which port
// was assigned when starting on port 0.
pub type Listener {
  Listener(name: process.Name(listener.Message))
}

pub fn server_child_with_listener(
  world: process.Name(world.Message),
  entrance: room.Id,
  port: Int,
) -> #(supervision.ChildSpecification(static_supervisor.Supervisor), Listener) {
  let listener_name = process.new_name("glisten_listener")
  let child =
    glisten.new(on_init(world, entrance), loop)
    |> glisten.with_active_state(options.Once)
    |> glisten.with_pool_size(10)
    |> glisten.bind("::")
    |> glisten.with_close(on_close)
    |> glisten.with_listener_name(listener_name)
    |> glisten.supervised(port)
  #(child, Listener(listener_name))
}

pub fn listener_port(listener: Listener, timeout: Int) -> Int {
  glisten.get_server_info(listener.name, timeout).port
}

pub fn on_init(
  world: process.Name(world.Message),
  entrance: room.Id,
) -> fn(Connection(session.Message)) ->
  #(session.State, Option(process.Selector(session.Message))) {
  fn(conn: Connection(session.Message)) -> #(
    session.State,
    Option(process.Selector(session.Message)),
  ) {
    case glisten.get_connection_info(conn) {
      Ok(conn_info) ->
        woof.debug("connection opened", [
          woof.str("ip", glisten.ip_address_to_string(conn_info.ip_address)),
        ])
      Error(_) -> woof.warning("connection info unavailable", [])
    }

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
  message: glisten.Message(session.Message),
  conn: Connection(session.Message),
) -> glisten.Next(session.State, glisten.Message(session.Message)) {
  let #(state, effects) = case message {
    glisten.Packet(chunk) -> session.receive_bytes(state, chunk)
    glisten.User(user_message) -> session.receive_message(state, user_message)
  }
  case runner.run_effects(state, sender(Some(conn)), effects) {
    Ok(state) -> glisten.continue(state)
    Error(reason) -> {
      let logger = runner.player_logger(state)
      let connection_fields = case glisten.get_connection_info(conn) {
        Ok(conn_info) -> [
          woof.str(
            "ip_address",
            glisten.ip_address_to_string(conn_info.ip_address),
          ),
        ]
        Error(_) -> []
      }
      case reason {
        runner.Requested ->
          logger
          |> woof.log(woof.Debug, "client requested quit", connection_fields)
        runner.SendFailed(reason) ->
          logger
          |> woof.log(woof.Warning, "send failed, disconnecting", [
            woof.str("reason", string.inspect(reason)),
            ..connection_fields
          ])
      }
      glisten.stop()
    }
  }
}

fn on_close(state: session.State) -> Nil {
  let _ =
    session.closed(state)
    |> runner.run_effects(state, sender(None), _)
  runner.player_logger(state)
  |> woof.log(woof.Debug, "connection closed by client", [])
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
