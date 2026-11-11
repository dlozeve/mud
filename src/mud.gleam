import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import mud/player
import mud/room

pub fn main() -> Nil {
  let room = "the dungeon entrance"
  let assert Ok(room_actor) =
    actor.new(room.State(
      id: room,
      description: "The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.",
      occupants: dict.new(),
    ))
    |> actor.on_message(room.handle_message)
    |> actor.start

  let alice = "Alice"
  let assert Ok(alice_actor) =
    actor.new(player.State(alice))
    |> actor.on_message(player.handle_message)
    |> actor.start

  let bob = "Bob"
  let assert Ok(bob_actor) =
    actor.new(player.State(bob))
    |> actor.on_message(player.handle_message)
    |> actor.start

  let carol = "Carol"
  let assert Ok(carol_actor) =
    actor.new(player.State(carol))
    |> actor.on_message(player.handle_message)
    |> actor.start

  room.enter(room_actor.data, alice, player.to_listener(alice_actor.data))
  room.enter(room_actor.data, bob, player.to_listener(bob_actor.data))
  room.enter(room_actor.data, carol, player.to_listener(carol_actor.data))
  room.say(room_actor.data, alice, "Hello everyone!")
  room.leave(room_actor.data, alice)
  room.leave(room_actor.data, carol)
  room.leave(room_actor.data, bob)

  process.sleep(100)
}
