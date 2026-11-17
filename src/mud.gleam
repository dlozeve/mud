import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import mud/direction
import mud/id
import mud/room
import mud/server
import mud/world

fn room_child(
  def: room.Def,
) -> supervision.ChildSpecification(Subject(room.Message)) {
  let state = room.State(def:, occupants: dict.new())
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(_, pid, _) -> room.Down(Some(pid))
            // unreachable
            process.PortDown(..) -> room.Down(None)
          }
        })
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(room.handle_message)
    |> actor.named(def.process_name)
    |> actor.start
  })
}

fn world_child(
  name: process.Name(world.Message),
  rooms: List(room.Def),
) -> supervision.ChildSpecification(Subject(world.Message)) {
  let rooms = dict.from_list(list.map(rooms, fn(r) { #(r.id, r) }))
  let state = world.State(rooms:, players: dict.new())
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(_, pid, _) -> world.Down(Some(pid))
            // unreachable
            process.PortDown(..) -> world.Down(None)
          }
        })
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(world.handle_message)
    |> actor.named(name)
    |> actor.start
  })
}

pub fn main() -> Nil {
  let entrance_id = id.new_room_id()
  let corridor_id = id.new_room_id()
  let entrance =
    room.Def(
      process_name: process.new_name("entrance"),
      id: entrance_id,
      name: "the dungeon entrance",
      description: "The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.",
      exits: dict.from_list([#(direction.North, corridor_id)]),
    )
  let corridor =
    room.Def(
      process_name: process.new_name("corridor"),
      id: corridor_id,
      name: "a dimly-lit corridor",
      description: "Long and narrow, with a few torches on the walls. Damp.",
      exits: dict.from_list([#(direction.South, entrance_id)]),
    )

  let entrance_child = room_child(entrance)
  let corridor_child = room_child(corridor)

  let world_name = process.new_name("world")
  let world_child = world_child(world_name, [entrance, corridor])

  let supervisor =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 5, period: 10)
    |> static_supervisor.add(entrance_child)
    |> static_supervisor.add(corridor_child)
    |> static_supervisor.add(world_child)
    |> static_supervisor.add(server.server_child(world_name, entrance.id, 3000))
    |> static_supervisor.start

  case supervisor {
    Ok(_) -> process.sleep_forever()
    Error(actor.InitTimeout) -> io.println_error("Timeout error")
    Error(actor.InitFailed(s)) ->
      io.println_error("Error during startup: " <> s)
    Error(actor.InitExited(_)) -> io.println_error("Init exited")
  }
}
