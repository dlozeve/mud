import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import mud/combat
import mud/direction
import mud/event
import mud/log
import mud/room
import woof

// Occupants are keyed by pid, so every test occupant needs its own.
fn occupant_with(name: String) -> room.Occupant {
  room.occupant(name, process.spawn(fn() { Nil }), event.Player, fn(_, _) {
    Nil
  })
}

fn npc_with(name: String) -> room.Occupant {
  room.occupant(name, process.spawn(fn() { Nil }), event.Npc, fn(_, _) { Nil })
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
  let #(_state, actions, _logs) = room.decide(state, room.Say(alice.pid, "hi"))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(alice.pid, event.YouSaid("hi")),
      room.Tell(bob.pid, event.OccupantSaid(alice.name, "hi", alice.kind)),
    ])
}

pub fn npc_say_broadcast_test() {
  let alice = occupant_with("Alice")
  let goblin = npc_with("a goblin")
  let state = state_with([alice, goblin])
  let #(_state, actions, _logs) =
    room.decide(state, room.Say(goblin.pid, "grrr"))
  // The NPC is not told about its own speech: there is no "you" to echo to.
  assert actions
    == [
      room.Tell(alice.pid, event.OccupantSaid("a goblin", "grrr", event.Npc)),
    ]
}

pub fn enter_broadcast_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob])
  let #(new_state, actions, _logs) = room.decide(state, room.Enter(carol))
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
      room.Tell(alice.pid, event.OccupantArrived(carol.name, carol.kind)),
      room.Tell(bob.pid, event.OccupantArrived(carol.name, carol.kind)),
    ])
  assert dict.size(new_state.occupants) == 3
  assert dict.get(new_state.occupants, alice.pid) == Ok(alice)
  assert dict.get(new_state.occupants, bob.pid) == Ok(bob)
  assert dict.get(new_state.occupants, carol.pid) == Ok(carol)
}

pub fn npc_enter_is_monitored_and_announced_test() {
  let alice = occupant_with("Alice")
  let goblin = npc_with("a goblin")
  let state = state_with([alice])
  let #(new_state, actions, _logs) = room.decide(state, room.Enter(goblin))
  // The NPC is monitored for eviction but, having no "you", is not sent the
  // second-person description of the room.
  assert set.from_list(actions)
    == set.from_list([
      room.Monitor(goblin.pid),
      room.Tell(alice.pid, event.OccupantArrived(goblin.name, event.Npc)),
    ])
  assert dict.get(new_state.occupants, goblin.pid) == Ok(goblin)
}

pub fn leave_broadcast_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob, carol])
  let #(_state, actions, _logs) = room.decide(state, room.Leave(alice.pid))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(bob.pid, event.OccupantLeft(alice.name, alice.kind)),
      room.Tell(carol.pid, event.OccupantLeft(alice.name, alice.kind)),
    ])
}

pub fn say_non_occupant_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob])
  let #(_state, actions, _logs) = room.decide(state, room.Say(carol.pid, "hi"))
  assert actions == []
}

pub fn leave_non_occupant_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let state = state_with([alice, bob])
  let #(_state, actions, _logs) = room.decide(state, room.Leave(carol.pid))
  assert actions == []
}

pub fn enter_twice_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let state = state_with([alice, bob])
  let #(new_state, actions, _logs) = room.decide(state, room.Enter(bob))
  assert actions == []
  assert dict.keys(state.occupants) == dict.keys(new_state.occupants)
}

// ----- Eviction ---------------------------------------------------------

fn occupant_with_pid(name: String, pid: process.Pid) -> room.Occupant {
  room.occupant(name, pid, event.Player, fn(_, _) { Nil })
}

pub fn npc_leave_broadcast_test() {
  let alice = occupant_with("Alice")
  let goblin = npc_with("a goblin")
  let state = state_with([alice, goblin])
  let #(new_state, actions, _logs) = room.decide(state, room.Leave(goblin.pid))
  assert actions
    == [room.Tell(alice.pid, event.OccupantLeft("a goblin", event.Npc))]
  assert !dict.has_key(new_state.occupants, goblin.pid)
}

pub fn down_evicts_a_dead_npc_test() {
  let goblin_pid = process.spawn(fn() { Nil })
  let goblin =
    room.occupant("a goblin", goblin_pid, event.Npc, fn(_, _) { Nil })
  let alice = occupant_with("Alice")
  let state = state_with([alice, goblin])
  let #(new_state, actions, _logs) =
    room.decide(state, room.Down(Some(goblin_pid)))
  assert actions
    == [room.Tell(alice.pid, event.OccupantLeft("a goblin", event.Npc))]
  assert !dict.has_key(new_state.occupants, goblin_pid)
}

pub fn down_evicts_the_occupant_test() {
  let alice_pid = process.spawn(fn() { Nil })
  let bob_pid = process.spawn(fn() { Nil })
  let alice = occupant_with_pid("Alice", alice_pid)
  let bob = occupant_with_pid("Bob", bob_pid)
  let state = state_with([alice, bob])

  let #(new_state, actions, _logs) =
    room.decide(state, room.Down(Some(alice_pid)))

  assert actions
    == [room.Tell(bob.pid, event.OccupantLeft(alice.name, alice.kind))]
  assert dict.has_key(new_state.occupants, bob.pid)
  assert !dict.has_key(new_state.occupants, alice.pid)
}

pub fn down_removes_a_dead_player_so_they_can_reenter_test() {
  let dead_pid = process.spawn(fn() { Nil })
  let alice = occupant_with_pid("Alice", dead_pid)
  let state = state_with([alice])

  let #(state, _, _logs) = room.decide(state, room.Down(Some(dead_pid)))

  // The same id can enter again, which is what a reconnecting player does.
  let #(new_state, actions, _logs) =
    room.decide(state, room.Enter(occupant_with_pid("Alice", process.self())))
  assert actions != []
  assert dict.size(new_state.occupants) == 1
}

pub fn down_of_an_unknown_process_is_ignored_test() {
  // `session_with` uses the test process itself as the pid, so use a different
  // one for the DOWN that should be ignored.
  let alice = occupant_with_pid("Alice", process.spawn(fn() { Nil }))
  let state = state_with([alice])
  let #(new_state, actions, _logs) =
    room.decide(state, room.Down(Some(process.self())))
  assert actions == []
  assert new_state == state
}

pub fn down_of_none_is_ignored_test() {
  // `session_with` uses the test process itself as the pid, so use a different
  // one for the DOWN that should be ignored.
  let alice = occupant_with_pid("Alice", process.spawn(fn() { Nil }))
  let state = state_with([alice])
  let #(new_state, actions, _logs) = room.decide(state, room.Down(None))
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

  let #(_state, actions, _logs) = room.decide(state, room.Enter(alice))

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

// ----- Combat -----------------------------------------------------------

pub fn attack_a_missing_npc_tells_the_attacker_test() {
  let alice = occupant_with("Alice")
  let state = state_with([alice])
  let #(_state, actions, _logs) =
    room.decide(state, room.Attack(alice.pid, "goblin", True))
  assert actions == [room.Tell(alice.pid, event.AttackFailed("goblin"))]
}

pub fn attack_hits_the_npc_test() {
  let alice = occupant_with("Alice")
  let goblin = npc_with("a goblin")
  let state = state_with([alice, goblin])
  let #(_state, actions, _logs) =
    room.decide(state, room.Attack(alice.pid, "a goblin", True))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(alice.pid, event.YouHitNpc("a goblin", combat.player_damage)),
      room.Tell(
        goblin.pid,
        event.NpcAttacked("Alice", alice.pid, combat.player_damage),
      ),
    ])
}

pub fn attack_misses_the_npc_test() {
  let alice = occupant_with("Alice")
  let goblin = npc_with("a goblin")
  let state = state_with([alice, goblin])
  let #(_state, actions, _logs) =
    room.decide(state, room.Attack(alice.pid, "a goblin", False))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(alice.pid, event.YouMissedNpc("a goblin")),
      room.Tell(goblin.pid, event.NpcAttacked("Alice", alice.pid, 0)),
    ])
}

pub fn attack_can_omit_the_article_test() {
  let alice = occupant_with("Alice")
  let goblin = npc_with("a goblin")
  let state = state_with([alice, goblin])
  let #(_state, actions, _logs) =
    room.decide(state, room.Attack(alice.pid, "goblin", True))
  assert set.from_list(actions)
    == set.from_list([
      room.Tell(alice.pid, event.YouHitNpc("a goblin", combat.player_damage)),
      room.Tell(
        goblin.pid,
        event.NpcAttacked("Alice", alice.pid, combat.player_damage),
      ),
    ])
}

pub fn attack_does_not_target_players_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let state = state_with([alice, bob])
  let #(_state, actions, _logs) =
    room.decide(state, room.Attack(alice.pid, "Bob", True))
  assert actions == [room.Tell(alice.pid, event.AttackFailed("Bob"))]
}

pub fn attack_by_a_non_occupant_is_ignored_test() {
  let alice = occupant_with("Alice")
  let goblin = npc_with("a goblin")
  let state = state_with([alice, goblin])
  let #(_state, actions, _logs) =
    room.decide(state, room.Attack(process.self(), "a goblin", True))
  assert actions == []
}

pub fn npc_attack_tells_the_target_player_test() {
  let alice = occupant_with("Alice")
  let goblin = npc_with("a goblin")
  let state = state_with([alice, goblin])
  let #(_state, actions, _logs) =
    room.decide(state, room.NpcAttack(goblin.pid, alice.pid, "a goblin", 1))
  assert actions == [room.Tell(alice.pid, event.NpcHitYou("a goblin", 1))]
}

pub fn npc_attack_on_a_missing_target_tells_the_npc_test() {
  let goblin = npc_with("a goblin")
  let state = state_with([goblin])
  let #(_state, actions, _logs) =
    room.decide(
      state,
      room.NpcAttack(goblin.pid, process.self(), "a goblin", 1),
    )
  assert actions == [room.Tell(goblin.pid, event.NpcTargetGone)]
}

pub fn death_broadcasts_and_removes_the_occupant_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let state = state_with([alice, bob])
  let #(new_state, actions, _logs) = room.decide(state, room.Died(alice.pid))
  assert actions
    == [room.Tell(bob.pid, event.OccupantDied(alice.name, alice.kind))]
  assert dict.has_key(new_state.occupants, bob.pid)
  assert !dict.has_key(new_state.occupants, alice.pid)
}

pub fn death_of_a_non_occupant_is_ignored_test() {
  let alice = occupant_with("Alice")
  let state = state_with([alice])
  let #(new_state, actions, _logs) =
    room.decide(state, room.Died(process.self()))
  assert actions == []
  assert new_state == state
}

pub fn who_is_here_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let carol = occupant_with("Carol")
  let goblin = npc_with("a goblin")
  let state = state_with([alice, bob, carol, goblin])
  let #(_, actions, _logs) = room.decide(state, room.WhoIsHere(carol.pid))
  let assert [room.Tell(pid, event.OccupantList(player_names:, npc_names:))] =
    actions
  assert pid == carol.pid
  assert set.from_list(player_names) == set.from_list([alice.name, bob.name])
  assert npc_names == [goblin.name]
}

// ----- Logging -----------------------------------------------------------

pub fn entering_twice_is_logged_as_a_warning_test() {
  let alice = occupant_with("Alice")
  let bob = occupant_with("Bob")
  let state = state_with([alice, bob])

  let #(_state, actions, logs) = room.decide(state, room.Enter(bob))

  assert actions == []
  let assert [log.Line(level: woof.Warning, message:, fields:)] = logs
  assert message == "occupant already in room"
  assert fields
    == [
      log.occupant_name("Bob"),
      log.occupant_pid(bob.pid),
      log.occupant_kind(bob.kind),
    ]
}

pub fn a_down_is_logged_before_the_leave_it_causes_test() {
  let alice_pid = process.spawn(fn() { Nil })
  let alice = occupant_with_pid("Alice", alice_pid)
  let state = state_with([alice])

  let #(_state, _actions, logs) = room.decide(state, room.Down(Some(alice_pid)))

  let assert [
    log.Line(message: "occupant process down", ..),
    log.Line(message: "occupant left room", ..),
  ] = logs
}
