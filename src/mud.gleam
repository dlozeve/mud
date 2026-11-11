import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import mud/player
import mud/room
import mud/types

pub fn main() -> Nil {
  let room = types.new_room_id("r1")
  let assert Ok(room_actor) =
    actor.new(room.State(
      id: room,
      name: "the dungeon entrance",
      description: "The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.",
      occupants: dict.new(),
    ))
    |> actor.on_message(room.handle_message)
    |> actor.start

  let alice = player.State(types.new_player_id("alice"), "Alice")
  let assert Ok(alice_actor) =
    actor.new(alice)
    |> actor.on_message(player.handle_message)
    |> actor.start
  let alice_session = player.to_session(alice_actor.data, alice)

  let bob = player.State(types.new_player_id("bob"), "Bob")
  let assert Ok(bob_actor) =
    actor.new(bob)
    |> actor.on_message(player.handle_message)
    |> actor.start
  let bob_session = player.to_session(bob_actor.data, bob)

  let carol = player.State(types.new_player_id("carol"), "Carol")
  let assert Ok(carol_actor) =
    actor.new(carol)
    |> actor.on_message(player.handle_message)
    |> actor.start
  let carol_session = player.to_session(carol_actor.data, carol)

  room.enter(room_actor.data, alice_session)
  room.enter(room_actor.data, bob_session)
  room.enter(room_actor.data, carol_session)
  room.say(room_actor.data, alice.id, "Hello everyone!")
  room.leave(room_actor.data, alice.id)
  room.leave(room_actor.data, carol.id)
  room.leave(room_actor.data, bob.id)

  process.sleep(100)
}
