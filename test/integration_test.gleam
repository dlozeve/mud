import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/charlist
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/string
import glisten/socket
import glisten/socket/options
import glisten/tcp
import mud/direction
import mud/event
import mud/player
import mud/room
import mud/runner
import mud/server
import mud/session
import mud/tree
import mud/world

// ----- Test harness -----------------------------------------------------

// The rooms run under a supervisor so that a killed room is restarted, as in
// the application. The world is started on its own so that a test can take it
// down and observe what the sessions do while it is unavailable.
type World {
  World(
    supervisor: process.Pid,
    world_pid: process.Pid,
    server_pid: Option(process.Pid),
    world: process.Name(world.Message),
    entrance: room.Def,
    corridor: room.Def,
  )
}

fn start_world() -> World {
  let entrance_id = room.new_id("entrance")
  let corridor_id = room.new_id("corridor")
  let entrance =
    room.Def(
      process_name: process.new_name("entrance"),
      id: entrance_id,
      name: "the dungeon entrance",
      description: "The bottom of an enormous stone staircase.",
      exits: dict.from_list([#(direction.North, corridor_id)]),
    )
  let corridor =
    room.Def(
      process_name: process.new_name("corridor"),
      id: corridor_id,
      name: "a dimly-lit corridor",
      description: "Long and narrow, with a few torches on the walls.",
      exits: dict.from_list([#(direction.South, entrance_id)]),
    )
  let rooms = [entrance, corridor]

  let assert Ok(supervisor) =
    tree.rooms_supervisor(rooms)
    |> static_supervisor.start

  let world_name = process.new_name("world")
  let spec = tree.world_child(world_name, rooms)
  let start = spec.start
  let assert Ok(started) = start()

  World(
    supervisor: supervisor.pid,
    world_pid: started.pid,
    server_pid: None,
    world: world_name,
    entrance: entrance,
    corridor: corridor,
  )
}

fn stop_world(world: World) -> Nil {
  process.unlink(world.supervisor)
  process.kill(world.supervisor)
  process.unlink(world.world_pid)
  process.kill(world.world_pid)
  case world.server_pid {
    Some(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    None -> Nil
  }
  Nil
}

// Start the real TCP server on port 0 and return the port the OS assigned.
fn start_world_with_server() -> #(World, Int) {
  let world = start_world()
  let #(child, listener) =
    server.server_child_with_listener(world.world, world.entrance.id, 0)
  let start = child.start
  let assert Ok(started) = start()
  #(
    World(..world, server_pid: Some(started.pid)),
    server.listener_port(listener, 1000),
  )
}

// A test-side session: it runs the real session logic and the real effect
// runner, with a sender that forwards output to the test process instead of a
// socket.
type Client {
  Client(
    id: Int,
    pid: process.Pid,
    input: process.Subject(String),
    events: process.Subject(Event),
  )
}

type Event {
  Ready(Client)
  Output(client: Int, text: String)
  Stopped(client: Int)
}

type DriverMessage {
  DriverSession(session.Message)
  DriverInput(String)
}

const welcome = "Welcome to the dungeon! What is your name?"

fn start_client(world: World, id: Int) -> Client {
  let events = process.new_subject()
  let _ =
    process.spawn(fn() { driver(id, world.world, world.entrance.id, events) })
  case process.receive(events, 2000) {
    Ok(Ready(client)) -> client
    Ok(Output(_, text)) -> panic as { "output before ready: " <> text }
    Ok(Stopped(_)) -> panic as "client stopped before ready"
    Error(_) -> panic as "client did not start"
  }
}

fn driver(
  id: Int,
  world: process.Name(world.Message),
  entrance: room.Id,
  events: process.Subject(Event),
) -> Nil {
  let subject = process.new_subject()
  let replies = process.new_subject()
  let input = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select_map(subject, DriverSession)
    |> process.select_map(replies, fn(reply) {
      DriverSession(session.WorldMessage(reply))
    })
    |> process.select_map(input, DriverInput)
    |> process.select_monitors(fn(down) {
      case down {
        process.ProcessDown(_, pid, _) ->
          DriverSession(session.RoomDown(Some(pid)))
        process.PortDown(..) -> DriverSession(session.RoomDown(None))
      }
    })
  let send = fn(text: String) -> Result(Nil, Nil) {
    process.send(events, Output(client: id, text:))
    Ok(Nil)
  }

  let #(state, effects) = session.started(subject, replies, world, entrance)
  process.send(events, Ready(Client(id:, pid: process.self(), input:, events:)))
  case runner.run_effects(state, send, effects) {
    Ok(state) -> driver_loop(id, state, selector, send, events)
    Error(_) -> {
      process.send(events, Stopped(id))
      Nil
    }
  }
}

fn driver_loop(
  id: Int,
  state: session.State,
  selector: process.Selector(DriverMessage),
  send: runner.Sender(Nil),
  events: process.Subject(Event),
) -> Nil {
  let message = process.selector_receive_forever(selector)
  let #(state, effects) = case message {
    DriverSession(message) -> session.receive_message(state, message)
    DriverInput(line) ->
      session.receive_bytes(state, bit_array.from_string(line <> "\n"))
  }
  case runner.run_effects(state, send, effects) {
    Ok(state) -> driver_loop(id, state, selector, send, events)
    Error(_) -> {
      process.send(events, Stopped(id))
      Nil
    }
  }
}

// ----- Assertions -------------------------------------------------------

fn send_line(client: Client, line: String) -> Nil {
  process.send(client.input, line)
  Nil
}

fn you_are_in(def: room.Def) -> String {
  player.render(event.YouAreIn(
    room_name: def.name,
    room_description: def.description,
    exits: list.filter(direction.all(), fn(each_direction) {
      dict.has_key(def.exits, each_direction)
    }),
  ))
}

fn expect_output(client: Client, expected_line: String) -> Nil {
  // Effects write a line at a time, so every message ends with a newline.
  let expected = expected_line <> "\n"
  case process.receive(client.events, 2000) {
    Ok(Output(_, actual)) if actual == expected -> Nil
    Ok(Output(_, actual)) ->
      panic as {
        "client "
        <> int.to_string(client.id)
        <> " got "
        <> actual
        <> " instead of "
        <> expected
      }
    Ok(Stopped(_)) -> panic as { "client stopped before output: " <> expected }
    Ok(Ready(_)) -> panic as "unexpected ready"
    Error(_) -> panic as { "timed out waiting for: " <> expected }
  }
}

fn expect_stopped(client: Client) -> Nil {
  case process.receive(client.events, 2000) {
    Ok(Stopped(_)) -> Nil
    Ok(Output(_, actual)) -> panic as { "output before stop: " <> actual }
    Ok(Ready(_)) -> panic as "unexpected ready"
    Error(_) -> panic as "timed out waiting for the client to stop"
  }
}

fn expect_no_output(client: Client) -> Nil {
  case process.receive(client.events, 100) {
    Error(_) -> Nil
    Ok(Output(_, actual)) -> panic as { "unexpected output: " <> actual }
    Ok(Stopped(_)) -> panic as "unexpected stop"
    Ok(Ready(_)) -> panic as "unexpected ready"
  }
}

// ----- T1: two clients ------------------------------------------------

pub fn two_clients_move_and_say_test() -> Nil {
  let world = start_world()
  let alice = start_client(world, 1)
  let bob = start_client(world, 2)

  expect_output(alice, welcome)
  expect_output(bob, welcome)

  send_line(alice, "Alice")
  expect_output(alice, you_are_in(world.entrance))

  send_line(bob, "Bob")
  expect_output(bob, you_are_in(world.entrance))
  expect_output(alice, "Bob arrives.")

  send_line(alice, "say hi")
  expect_output(alice, "You say: hi")
  expect_output(bob, "Alice says: hi")

  send_line(alice, "go north")
  expect_output(alice, you_are_in(world.corridor))
  expect_output(bob, "Alice leaves.")

  send_line(bob, "go north")
  expect_output(bob, you_are_in(world.corridor))
  expect_output(alice, "Bob arrives.")

  send_line(alice, "say hello")
  expect_output(alice, "You say: hello")
  expect_output(bob, "Alice says: hello")

  // A final look on each client is the barrier: its reply is emitted after
  // every earlier room event addressed to that client.
  send_line(alice, "look")
  expect_output(alice, you_are_in(world.corridor))
  send_line(bob, "look")
  expect_output(bob, you_are_in(world.corridor))

  expect_no_output(alice)
  expect_no_output(bob)

  send_line(alice, "quit")
  expect_stopped(alice)
  expect_output(bob, "Alice leaves.")
  send_line(bob, "quit")
  expect_stopped(bob)

  stop_world(world)
}

// ----- T1b: combat -----------------------------------------------------

pub fn attacking_a_missing_npc_reports_no_target_test() -> Nil {
  let world = start_world()
  let alice = start_client(world, 1)

  expect_output(alice, welcome)
  send_line(alice, "Alice")
  expect_output(alice, you_are_in(world.entrance))

  send_line(alice, "attack goblin")
  expect_output(alice, "There is no goblin here.")

  send_line(alice, "quit")
  expect_stopped(alice)
  stop_world(world)
}

pub fn lethal_npc_attack_kills_the_player_and_tells_the_room_test() -> Nil {
  let world = start_world()
  let alice = start_client(world, 1)
  let bob = start_client(world, 2)

  expect_output(alice, welcome)
  expect_output(bob, welcome)

  send_line(alice, "Alice")
  expect_output(alice, you_are_in(world.entrance))

  send_line(bob, "Bob")
  expect_output(bob, you_are_in(world.entrance))
  expect_output(alice, "Bob arrives.")

  // Drive the room directly: the attack is deterministic, unlike a real NPC's
  // hit roll. A damage value at least as large as the player's hp is lethal.
  let _ =
    room.npc_attack(
      world.entrance.process_name,
      process.self(),
      alice.pid,
      "a goblin",
      100,
    )

  expect_output(alice, "You died")
  expect_stopped(alice)
  expect_output(bob, "Alice has died.")
  expect_no_output(bob)

  send_line(bob, "quit")
  expect_stopped(bob)
  stop_world(world)
}

// ----- T2: restarts ----------------------------------------------------

pub fn room_restart_reenters_test() -> Nil {
  let world = start_world()
  let alice = start_client(world, 1)
  let bob = start_client(world, 2)

  expect_output(alice, welcome)
  expect_output(bob, welcome)

  send_line(alice, "Alice")
  expect_output(alice, you_are_in(world.entrance))

  send_line(bob, "Bob")
  expect_output(bob, you_are_in(world.entrance))
  expect_output(alice, "Bob arrives.")

  // Put the players in different rooms so that each re-entry is independent.
  send_line(bob, "go north")
  expect_output(bob, you_are_in(world.corridor))
  expect_output(alice, "Bob leaves.")

  // Kill the entrance: Alice is told it went down, waits for the supervisor
  // to restart it, and enters the new incarnation.
  let assert Ok(old_entrance) = process.named(world.entrance.process_name)
  process.kill(old_entrance)
  expect_output(alice, you_are_in(world.entrance))
  let assert Ok(new_entrance) = process.named(world.entrance.process_name)
  assert new_entrance != old_entrance

  // Bob was in the corridor and must not be disturbed by the entrance restart.
  send_line(bob, "look")
  expect_output(bob, you_are_in(world.corridor))
  expect_no_output(bob)

  let assert Ok(old_corridor) = process.named(world.corridor.process_name)
  process.kill(old_corridor)
  expect_output(bob, you_are_in(world.corridor))
  let assert Ok(new_corridor) = process.named(world.corridor.process_name)
  assert new_corridor != old_corridor

  send_line(alice, "look")
  expect_output(alice, you_are_in(world.entrance))
  expect_no_output(alice)

  // The new incarnations accepted them back as occupants.
  send_line(alice, "say hi")
  expect_output(alice, "You say: hi")
  send_line(bob, "say hi")
  expect_output(bob, "You say: hi")

  send_line(alice, "quit")
  expect_stopped(alice)
  send_line(bob, "quit")
  expect_stopped(bob)

  stop_world(world)
}

pub fn world_down_reports_and_session_drops_cleanly_test() -> Nil {
  let world = start_world()
  let alice = start_client(world, 1)
  let bob = start_client(world, 2)

  expect_output(alice, welcome)
  expect_output(bob, welcome)

  send_line(alice, "Alice")
  expect_output(alice, you_are_in(world.entrance))

  send_line(bob, "Bob")
  expect_output(bob, you_are_in(world.entrance))
  expect_output(alice, "Bob arrives.")

  // The world is not supervised in this harness, so taking it down keeps it
  // down instead of racing a restart.
  process.unlink(world.world_pid)
  process.kill(world.world_pid)

  send_line(alice, "go north")
  expect_output(alice, "The world is restarting, try again.")

  // The room is still up, so looking and leaving the game still work.
  send_line(alice, "look")
  expect_output(alice, you_are_in(world.entrance))
  expect_no_output(bob)

  send_line(alice, "quit")
  expect_stopped(alice)
  expect_output(bob, "Alice leaves.")
  send_line(bob, "quit")
  expect_stopped(bob)

  stop_world(world)
}

// ----- T3: eviction ----------------------------------------------------

const name_in_use = "This name is already in use. Choose another name: "

// The room and the world both discover a dead player through monitors, but
// their DOWN messages are independent. The room can broadcast the departure
// before the world has freed the name, so retry the join for a short while.
fn join_with_retry(client: Client, name: String, room: room.Def) -> Nil {
  join_with_retry_attempt(client, name, room, 50)
}

fn join_with_retry_attempt(
  client: Client,
  name: String,
  room: room.Def,
  attempts: Int,
) -> Nil {
  let joined = you_are_in(room) <> "\n"
  let in_use = name_in_use <> "\n"
  send_line(client, name)
  case process.receive(client.events, 2000) {
    Ok(Output(_, actual)) if actual == joined -> Nil
    Ok(Output(_, actual)) if actual == in_use -> {
      assert attempts > 0
      process.sleep(10)
      join_with_retry_attempt(client, name, room, attempts - 1)
    }
    Ok(Output(_, actual)) ->
      panic as { "unexpected output while joining: " <> actual }
    Ok(Stopped(_)) -> panic as "client stopped while joining"
    Ok(Ready(_)) -> panic as "unexpected ready"
    Error(_) -> panic as "timed out while joining"
  }
}

pub fn killed_session_is_evicted_and_name_freed_test() -> Nil {
  let world = start_world()
  let alice = start_client(world, 1)
  let bob = start_client(world, 2)

  expect_output(alice, welcome)
  expect_output(bob, welcome)

  send_line(alice, "Alice")
  expect_output(alice, you_are_in(world.entrance))

  send_line(bob, "Bob")
  expect_output(bob, you_are_in(world.entrance))
  expect_output(alice, "Bob arrives.")

  // Kill Alice's connection process. The room monitors it and evicts her.
  process.unlink(alice.pid)
  process.kill(alice.pid)
  expect_output(bob, "Alice leaves.")

  // The name is free again: a new session can take it.
  let alice_again = start_client(world, 3)
  expect_output(alice_again, welcome)
  join_with_retry(alice_again, "Alice", world.entrance)
  expect_output(bob, "Alice arrives.")

  // The new session is a real occupant.
  send_line(alice_again, "say hi")
  expect_output(alice_again, "You say: hi")
  expect_output(bob, "Alice says: hi")

  send_line(alice_again, "quit")
  expect_stopped(alice_again)
  expect_output(bob, "Alice leaves.")
  send_line(bob, "quit")
  expect_stopped(bob)

  stop_world(world)
}

// ----- T4: real sockets -------------------------------------------------

type Reader {
  Reader(socket: socket.Socket, buffer: String)
}

@external(erlang, "gen_tcp", "connect")
fn do_connect(
  address: charlist.Charlist,
  port: Int,
  tcp_options: List(options.ErlangTcpOption),
) -> Result(socket.Socket, socket.SocketReason)

fn connect(port: Int) -> Reader {
  let tcp_options =
    [options.Mode(options.Binary), options.ActiveMode(options.Passive)]
    |> options.to_erl_options
  let assert Ok(sock) =
    do_connect(charlist.from_string("127.0.0.1"), port, tcp_options)
  Reader(socket: sock, buffer: "")
}

// TCP is a stream: a single receive can return part of a line or several
// lines, so keep the unread tail in the reader.
fn read_line(reader: Reader) -> #(Reader, String) {
  case string.split_once(reader.buffer, "\n") {
    Ok(#(line, rest)) -> #(Reader(..reader, buffer: rest), line)
    Error(_) ->
      case tcp.receive_timeout(reader.socket, 0, 5000) {
        Ok(chunk) -> {
          let text = case bit_array.to_string(chunk) {
            Ok(text) -> text
            Error(_) -> panic as "server sent invalid utf-8"
          }
          read_line(Reader(..reader, buffer: reader.buffer <> text))
        }
        Error(reason) ->
          panic as { "receive failed: " <> socket.reason_to_string(reason) }
      }
  }
}

fn expect_lines(reader: Reader, expected: List(String)) -> Reader {
  list.fold(expected, reader, fn(reader, line) {
    let #(reader, actual) = read_line(reader)
    case actual == line {
      True -> reader
      False ->
        panic as { "expected \"" <> line <> "\", got \"" <> actual <> "\"" }
    }
  })
}

fn write_line(reader: Reader, line: String) -> Nil {
  let assert Ok(_) =
    tcp.send(reader.socket, bytes_tree.from_string(line <> "\n"))
  Nil
}

fn expect_closed(reader: Reader) -> Nil {
  case tcp.receive_timeout(reader.socket, 0, 5000) {
    Error(socket.Closed) -> Nil
    Error(reason) ->
      panic as {
        "expected the connection to close, got "
        <> socket.reason_to_string(reason)
      }
    Ok(_) -> panic as "expected the connection to close, got data"
  }
}

fn close_reader(reader: Reader) -> Nil {
  let _ = tcp.close(reader.socket)
  Nil
}

pub fn socket_end_to_end_test() -> Nil {
  let #(world, port) = start_world_with_server()
  let alice = connect(port)
  let bob = connect(port)

  let alice = expect_lines(alice, [welcome])
  let bob = expect_lines(bob, [welcome])

  write_line(alice, "Alice")
  let alice =
    expect_lines(alice, string.split(you_are_in(world.entrance), "\n"))

  write_line(bob, "Bob")
  let bob = expect_lines(bob, string.split(you_are_in(world.entrance), "\n"))
  let alice = expect_lines(alice, ["Bob arrives."])

  write_line(alice, "look")
  let alice =
    expect_lines(alice, string.split(you_are_in(world.entrance), "\n"))

  write_line(alice, "go north")
  let alice =
    expect_lines(alice, string.split(you_are_in(world.corridor), "\n"))
  let bob = expect_lines(bob, ["Alice leaves."])

  write_line(bob, "go north")
  let bob = expect_lines(bob, string.split(you_are_in(world.corridor), "\n"))
  let alice = expect_lines(alice, ["Bob arrives."])

  write_line(alice, "say hi")
  let alice = expect_lines(alice, ["You say: hi"])
  let bob = expect_lines(bob, ["Alice says: hi"])

  write_line(alice, "quit")
  expect_closed(alice)
  let bob = expect_lines(bob, ["Alice leaves."])

  write_line(bob, "quit")
  expect_closed(bob)

  close_reader(alice)
  close_reader(bob)
  stop_world(world)
}
