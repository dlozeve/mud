import gleam/dict
import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor
import mud/direction
import mud/room
import mud/server
import mud/tree

pub fn main() -> Nil {
  let entrance_id = room.new_id()
  let corridor_id = room.new_id()
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

  let rooms = [entrance, corridor]
  let world_name = process.new_name("world")

  let supervisor =
    tree.rooms_supervisor(rooms)
    |> static_supervisor.add(tree.world_child(world_name, rooms))
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
