import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import mud/id
import mud/player
import mud/room
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
          ),
        ),
        #(
          room.id,
          world.RoomInfo(
            room_actor.data,
            id: room.id,
            name: "a dimly-lit corridor",
            description: "Long and narrow, with a few torches on the walls. Damp.",
          ),
        ),
      ]),
      members: dict.new(),
    ))
    |> actor.on_message(world.handle_message)
    |> actor.start

  let alice = player.State(id.new_player_id("alice"), "Alice", world_actor.data)
  let assert Ok(alice_actor) =
    actor.new(alice)
    |> actor.on_message(player.handle_message)
    |> actor.start
  let alice_session = player.to_session(alice_actor.data, alice)

  let bob = player.State(id.new_player_id("bob"), "Bob", world_actor.data)
  let assert Ok(bob_actor) =
    actor.new(bob)
    |> actor.on_message(player.handle_message)
    |> actor.start
  let bob_session = player.to_session(bob_actor.data, bob)

  let carol = player.State(id.new_player_id("carol"), "Carol", world_actor.data)
  let assert Ok(carol_actor) =
    actor.new(carol)
    |> actor.on_message(player.handle_message)
    |> actor.start
  let carol_session = player.to_session(carol_actor.data, carol)

  world.join(world_actor.data, alice_session, entrance.id)
  world.join(world_actor.data, bob_session, entrance.id)
  world.join(world_actor.data, carol_session, entrance.id)

  player.move(alice_actor.data, room.id)
  player.move(bob_actor.data, room.id)
  player.move(carol_actor.data, room.id)

  process.sleep(50)

  player.input(alice_actor.data, "Hello everyone!")

  process.sleep(100)

  player.disconnect(alice_actor.data)
  player.disconnect(carol_actor.data)
  player.disconnect(bob_actor.data)

  process.sleep(50)
}
