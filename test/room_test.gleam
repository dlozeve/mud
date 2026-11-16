import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import mud/direction
import mud/event
import mud/id
import mud/room

fn session_with(name: String) -> event.Session {
  event.Session(
    id.new_player_id(name <> "_id"),
    name,
    process.self(),
    event.Listener(fn(_, _) { Nil }),
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
      room.Monitor(carol.pid),
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

// ----- Eviction ---------------------------------------------------------

fn session_with_pid(name: String, pid: process.Pid) -> event.Session {
  event.Session(
    id.new_player_id(name <> "_id"),
    name,
    pid,
    event.Listener(fn(_, _) { Nil }),
  )
}

pub fn down_evicts_the_occupant_test() {
  let alice_pid = process.spawn(fn() { Nil })
  let bob_pid = process.spawn(fn() { Nil })
  let alice = session_with_pid("Alice", alice_pid)
  let bob = session_with_pid("Bob", bob_pid)
  let state = state_with([alice, bob])

  let #(new_state, actions) = room.decide(state, room.Down(Some(alice_pid)))

  assert actions == [room.Tell(bob.id, event.PlayerLeft(alice.name))]
  assert dict.has_key(new_state.occupants, bob.id)
  assert !dict.has_key(new_state.occupants, alice.id)
}

pub fn down_removes_a_dead_player_so_they_can_reenter_test() {
  let dead_pid = process.spawn(fn() { Nil })
  let alice = session_with_pid("Alice", dead_pid)
  let state = state_with([alice])

  let #(state, _) = room.decide(state, room.Down(Some(dead_pid)))

  // The same id can enter again, which is what a reconnecting player does.
  let #(new_state, actions) =
    room.decide(state, room.Enter(session_with_pid("Alice", process.self())))
  assert actions != []
  assert dict.size(new_state.occupants) == 1
}

pub fn down_of_an_unknown_process_is_ignored_test() {
  // `session_with` uses the test process itself as the pid, so use a different
  // one for the DOWN that should be ignored.
  let alice = session_with_pid("Alice", process.spawn(fn() { Nil }))
  let state = state_with([alice])
  let #(new_state, actions) =
    room.decide(state, room.Down(Some(process.self())))
  assert actions == []
  assert new_state == state
}

pub fn down_of_none_is_ignored_test() {
  // `session_with` uses the test process itself as the pid, so use a different
  // one for the DOWN that should be ignored.
  let alice = session_with_pid("Alice", process.spawn(fn() { Nil }))
  let state = state_with([alice])
  let #(new_state, actions) = room.decide(state, room.Down(None))
  assert actions == []
  assert new_state == state
}

pub fn you_are_in_lists_exits_in_a_fixed_order_test() {
  // Inserted West first, so a plain `dict.keys` would report West, North.
  let def =
    room.Def(
      process_name: process.new_name("r1"),
      id: id.new_room_id("r1"),
      name: "room",
      description: "room description",
      exits: dict.from_list([
        #(direction.West, id.new_room_id("west")),
        #(direction.North, id.new_room_id("north")),
      ]),
    )
  let state = room.State(def:, occupants: dict.new())
  let alice = session_with("Alice")

  let #(_state, actions) = room.decide(state, room.Enter(alice))

  assert actions
    == [
      room.Monitor(alice.pid),
      room.Tell(
        alice.id,
        event.YouAreIn(
          room_name: "room",
          room_description: "room description",
          exits: [direction.North, direction.West],
        ),
      ),
    ]
}
