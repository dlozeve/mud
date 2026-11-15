import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/set
import mud/event
import mud/id
import mud/room

fn session_with(name: String) -> event.Session {
  event.Session(
    id.new_player_id(name <> "_id"),
    name,
    event.Listener(fn(_) { Nil }),
  )
}

fn state_with(sessions: List(event.Session)) -> room.State {
  room.State(
    def: room.Def(
      process_name: process.new_name("r1"),
      id: id.new_room_id("r1"),
      name: "room",
      description: "room description",
      exits: dict.new(),
    ),
    occupants: dict.from_list(
      list.map(sessions, fn(session) { #(session.id, session) }),
    ),
  )
}

pub fn say_broadcast_test() {
  let alice = session_with("Alice")
  let bob = session_with("Bob")
  let state = state_with([alice, bob])
  let #(_state, actions) = room.decide(state, room.Say(alice.id, "hi"))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(alice.id, event.YouSaid("hi")),
      room.Tell(bob.id, event.PlayerSaid(alice.name, "hi")),
    ])
}

pub fn enter_broadcast_test() {
  let alice = session_with("Alice")
  let bob = session_with("Bob")
  let carol = session_with("Carol")
  let state = state_with([alice, bob])
  let #(new_state, actions) = room.decide(state, room.Enter(carol))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(
        carol.id,
        event.YouAreIn(
          room_name: state.def.name,
          room_description: state.def.description,
          exits: dict.keys(state.def.exits),
        ),
      ),
      room.Tell(alice.id, event.PlayerArrived(carol.name)),
      room.Tell(bob.id, event.PlayerArrived(carol.name)),
    ])
  assert dict.size(new_state.occupants) == 3
  assert dict.get(new_state.occupants, alice.id) == Ok(alice)
  assert dict.get(new_state.occupants, bob.id) == Ok(bob)
  assert dict.get(new_state.occupants, carol.id) == Ok(carol)
}

pub fn leave_broadcast_test() {
  let alice = session_with("Alice")
  let bob = session_with("Bob")
  let carol = session_with("Carol")
  let state = state_with([alice, bob, carol])
  let #(_state, actions) = room.decide(state, room.Leave(alice.id))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(bob.id, event.PlayerLeft(alice.name)),
      room.Tell(carol.id, event.PlayerLeft(alice.name)),
    ])
}

pub fn say_non_occupant_test() {
  let alice = session_with("Alice")
  let bob = session_with("Bob")
  let carol = session_with("Carol")
  let state = state_with([alice, bob])
  let #(_state, actions) = room.decide(state, room.Say(carol.id, "hi"))
  assert actions == []
}

pub fn leave_non_occupant_test() {
  let alice = session_with("Alice")
  let bob = session_with("Bob")
  let carol = session_with("Carol")
  let state = state_with([alice, bob])
  let #(_state, actions) = room.decide(state, room.Leave(carol.id))
  assert actions == []
}

pub fn enter_twice_test() {
  let alice = session_with("Alice")
  let bob = session_with("Bob")
  let state = state_with([alice, bob])
  let #(new_state, actions) = room.decide(state, room.Enter(bob))
  assert actions == []
  assert dict.keys(state.occupants) == dict.keys(new_state.occupants)
}
