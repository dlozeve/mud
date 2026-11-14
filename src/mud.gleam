import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import mud/direction
import mud/id.{type RoomId}
import mud/room
import mud/server
import mud/world

fn room_child(
  name: process.Name(room.Message),
  id: RoomId,
) -> supervision.ChildSpecification(Subject(room.Message)) {
  let state = room.State(id:, occupants: dict.new())
  supervision.worker(fn() {
    actor.new(state)
    |> actor.on_message(room.handle_message)
    |> actor.named(name)
    |> actor.start
  })
}

fn world_child(
  name: process.Name(world.Message),
  rooms: List(world.RoomInfo),
) -> supervision.ChildSpecification(Subject(world.Message)) {
  let rooms = dict.from_list(list.map(rooms, fn(r) { #(r.id, r) }))
  let state = world.State(rooms:, members: dict.new())
  supervision.worker(fn() {
    actor.new(state)
    |> actor.on_message(world.handle_message)
    |> actor.named(name)
    |> actor.start
  })
}

pub fn main() -> Nil {
  let entrance_id = id.new_room_id("entrance")
  let entrance_name = process.new_name("entrance")

  let corridor_id = id.new_room_id("corridor")
  let corridor_name = process.new_name("corridor")

  let entrance =
    world.RoomInfo(
      process_name: entrance_name,
      id: entrance_id,
      name: "the dungeon entrance",
      description: "The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.",
      exits: dict.from_list([#(direction.North, corridor_id)]),
    )
  let corridor =
    world.RoomInfo(
      process_name: corridor_name,
      id: corridor_id,
      name: "a dimly-lit corridor",
      description: "Long and narrow, with a few torches on the walls. Damp.",
      exits: dict.from_list([#(direction.South, entrance_id)]),
    )

  let entrance_child = room_child(entrance_name, entrance_id)
  let corridor_child = room_child(corridor_name, corridor_id)

  let world_name = process.new_name("world")
  let world_child = world_child(world_name, [entrance, corridor])

  let supervisor =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 5, period: 10)
    |> static_supervisor.add(entrance_child)
    |> static_supervisor.add(corridor_child)
    |> static_supervisor.add(world_child)
    |> static_supervisor.add(server.server_child(
      process.named_subject(world_name),
      entrance.id,
      3000,
    ))
    |> static_supervisor.start

  case supervisor {
    Ok(_) -> process.sleep_forever()
    Error(actor.InitTimeout) -> io.println_error("Timeout error")
    Error(actor.InitFailed(s)) ->
      io.println_error("Error during startup: " <> s)
    Error(actor.InitExited(_)) -> io.println_error("Init exited")
  }
}
