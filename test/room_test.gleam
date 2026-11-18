import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import mud/direction
import mud/event
import mud/room

// Occupants are keyed by pid, so every test occupant needs its own.
fn occupant_with(name: String) -> room.Occupant {
  room.occupant(name, process.spawn(fn() { Nil }), fn(_, _) { Nil })
}

fn state_with(occupants: List(room.Occupant)) -> room.State {
  room.State(
    def: room.Def(
      process_name: process.new_name("r1"),
      id: room.new_id("r1"),
      name: "room",
      description: "room description",
      exits: dict.new(),
    ),
    occupants: dict.from_list(
      list.map(occupants, fn(occupant) { #(occupant.pid, occupant) }),
    ),
  )
}

pub fn say_broadcast_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let state = state_with([alice, bob])
  let #(_state, actions) = room.decide(state, room.Say(alice.pid, "hi"))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(alice.pid, event.YouSaid("hi")),
      room.Tell(bob.pid, event.PlayerSaid(alice.name, "hi")),
    ])
}

pub fn enter_broadcast_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob])
  let #(new_state, actions) = room.decide(state, room.Enter(carol))
  assert set.from_list(actions)
    == set.from_list([
      room.Monitor(carol.pid),
      room.Tell(
        carol.pid,
        event.YouAreIn(
          room_name: state.def.name,
          room_description: state.def.description,
          exits: dict.keys(state.def.exits),
        ),
      ),
      room.Tell(alice.pid, event.PlayerArrived(carol.name)),
      room.Tell(bob.pid, event.PlayerArrived(carol.name)),
    ])
  assert dict.size(new_state.occupants) == 3
  assert dict.get(new_state.occupants, alice.pid) == Ok(alice)
  assert dict.get(new_state.occupants, bob.pid) == Ok(bob)
  assert dict.get(new_state.occupants, carol.pid) == Ok(carol)
}

pub fn leave_broadcast_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob, carol])
  let #(_state, actions) = room.decide(state, room.Leave(alice.pid))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(bob.pid, event.PlayerLeft(alice.name)),
      room.Tell(carol.pid, event.PlayerLeft(alice.name)),
    ])
}

pub fn say_non_occupant_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob])
  let #(_state, actions) = room.decide(state, room.Say(carol.pid, "hi"))
  assert actions == []
}

pub fn leave_non_occupant_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob])
  let #(_state, actions) = room.decide(state, room.Leave(carol.pid))
  assert actions == []
}

pub fn enter_twice_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let state = state_with([alice, bob])
  let #(new_state, actions) = room.decide(state, room.Enter(bob))
  assert actions == []
  assert dict.keys(state.occupants) == dict.keys(new_state.occupants)
}

// ----- Eviction ---------------------------------------------------------

fn occupant_with_pid(name: String, pid: process.Pid) -> room.Occupant {
  room.occupant(name, pid, fn(_, _) { Nil })
}

pub fn down_evicts_the_occupant_test() {
  let alice_pid = process.spawn(fn() { Nil })
  let bob_pid = process.spawn(fn() { Nil })
  let alice = occupant_with_pid("Alice", alice_pid)
  let bob = occupant_with_pid("Bob", bob_pid)
  let state = state_with([alice, bob])

  let #(new_state, actions) = room.decide(state, room.Down(Some(alice_pid)))

  assert actions == [room.Tell(bob.pid, event.PlayerLeft(alice.name))]
  assert dict.has_key(new_state.occupants, bob.pid)
  assert !dict.has_key(new_state.occupants, alice.pid)
}

pub fn down_removes_a_dead_player_so_they_can_reenter_test() {
  let dead_pid = process.spawn(fn() { Nil })
  let alice = occupant_with_pid("Alice", dead_pid)
  let state = state_with([alice])

  let #(state, _) = room.decide(state, room.Down(Some(dead_pid)))

  // The same id can enter again, which is what a reconnecting player does.
  let #(new_state, actions) =
    room.decide(state, room.Enter(occupant_with_pid("Alice", process.self())))
  assert actions != []
  assert dict.size(new_state.occupants) == 1
}

pub fn down_of_an_unknown_process_is_ignored_test() {
  // `session_with` uses the test process itself as the pid, so use a different
  // one for the DOWN that should be ignored.
  let alice = occupant_with_pid("Alice", process.spawn(fn() { Nil }))
  let state = state_with([alice])
  let #(new_state, actions) =
    room.decide(state, room.Down(Some(process.self())))
  assert actions == []
  assert new_state == state
}

pub fn down_of_none_is_ignored_test() {
  // `session_with` uses the test process itself as the pid, so use a different
  // one for the DOWN that should be ignored.
  let alice = occupant_with_pid("Alice", process.spawn(fn() { Nil }))
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
      id: room.new_id("r1"),
      name: "room",
      description: "room description",
      exits: dict.from_list([
        #(direction.West, room.new_id("r2")),
        #(direction.North, room.new_id("r3")),
      ]),
    )
  let state = room.State(def:, occupants: dict.new())
  let alice = occupant_with("Alice")

  let #(_state, actions) = room.decide(state, room.Enter(alice))

  assert actions
    == [
      room.Monitor(alice.pid),
      room.Tell(
        alice.pid,
        event.YouAreIn(
          room_name: "room",
          room_description: "room description",
          exits: [direction.North, direction.West],
        ),
      ),
    ]
}

pub fn who_is_here_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob, carol])
  let #(_, actions) = room.decide(state, room.WhoIsHere(carol.pid))
  let assert [room.Tell(pid, event.OccupantList(names:))] = actions
  assert pid == carol.pid
  assert set.from_list(names) == set.from_list([alice.name, bob.name])
}
