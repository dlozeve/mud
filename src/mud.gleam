import gleam/dict
import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import mud/direction
import mud/id
import mud/room
import mud/server
import mud/world

pub fn main() -> Nil {
  let entrance = room.State(id: id.new_room_id("r1"), occupants: dict.new())
  let assert Ok(entrance_actor) =
    actor.new(entrance)
    |> actor.on_message(room.handle_message)
    |> actor.start

  let room = room.State(id: id.new_room_id("r2"), occupants: dict.new())
  let assert Ok(room_actor) =
    actor.new(room)
    |> actor.on_message(room.handle_message)
    |> actor.start

  let assert Ok(world_actor) =
    actor.new(world.State(
      rooms: dict.from_list([
        #(
          entrance.id,
          world.RoomInfo(
            entrance_actor.data,
            id: entrance.id,
            name: "the dungeon entrance",
            description: "The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.",
            exits: dict.from_list([#(direction.North, room.id)]),
          ),
        ),
        #(
          room.id,
          world.RoomInfo(
            room_actor.data,
            id: room.id,
            name: "a dimly-lit corridor",
            description: "Long and narrow, with a few torches on the walls. Damp.",
            exits: dict.from_list([#(direction.South, entrance.id)]),
          ),
        ),
      ]),
      members: dict.new(),
    ))
    |> actor.on_message(world.handle_message)
    |> actor.start

  case server.start(world_actor.data, entrance.id, 3000) {
    Ok(_) -> process.sleep_forever()
    Error(_) -> io.println_error("Could not start the server on port 3000.")
  }
}
