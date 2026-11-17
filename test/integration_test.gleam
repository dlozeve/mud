import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import mud/direction
import mud/event
import mud/player
import mud/room
import mud/runner
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
    world: process.Name(world.Message),
    entrance: room.Def,
    corridor: room.Def,
  )
}

fn start_world() -> World {
  let entrance_id = room.new_id()
  let corridor_id = room.new_id()
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
  Nil
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
    exits: list.filter(direction.all(), fn(d) { dict.has_key(def.exits, d) }),
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

pub fn two_clients_move_and_say_test() {
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
