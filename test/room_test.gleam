import gleam/dict
import gleam/list
import mud/event
import mud/room
import mud/types.{type PlayerId}

fn state_with(players: List(PlayerId)) -> room.State {
  let noop_listener = event.Listener(fn(_) { Nil })
  room.State(
    id: "r1",
    description: "dark",
    occupants: dict.from_list(
      list.map(players, fn(player) { #(player, noop_listener) }),
    ),
  )
}

pub fn say_broadcast_test() {
  let state = state_with(["Alice", "Bob"])
  let #(_state, actions) = room.decide(state, room.Say("Alice", "hi"))
  assert actions
    == [
      room.Tell("Alice", event.PlayerSaid("Alice", "hi")),
      room.Tell("Bob", event.PlayerSaid("Alice", "hi")),
    ]
}

pub fn enter_broadcast_test() {
  let state = state_with(["Alice", "Bob"])
  let #(_state, actions) =
    room.decide(
      state,
      room.PlayerEntered("Alice", event.Listener(fn(_) { Nil })),
    )
  assert actions
    == [
      room.Tell("Alice", event.PlayerEntered("Alice")),
      room.Tell("Bob", event.PlayerEntered("Alice")),
      room.Tell("Alice", event.RoomDescribed(state.description)),
    ]
}

pub fn leave_broadcast_test() {
  let state = state_with(["Alice", "Bob", "Carol"])
  let #(_state, actions) = room.decide(state, room.PlayerLeft("Alice"))
  assert actions
    == [
      room.Tell("Bob", event.PlayerLeft("Alice")),
      room.Tell("Carol", event.PlayerLeft("Alice")),
    ]
}

pub fn say_non_occupant_test() {
  let state = state_with(["Alice", "Bob"])
  let #(_state, actions) = room.decide(state, room.Say("Carol", "hi"))
  assert actions == []
}

pub fn leave_non_occupant_test() {
  let state = state_with(["Alice", "Bob"])
  let #(_state, actions) = room.decide(state, room.PlayerLeft("Carol"))
  assert actions == []
}
