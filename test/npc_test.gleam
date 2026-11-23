import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import mud/combat
import mud/event
import mud/log
import mud/npc
import mud/room
import woof

fn room_def() -> room.Def {
  room.Def(
    process_name: process.new_name("npc-room"),
    id: room.new_id("npc-room"),
    name: "a room",
    description: "A room.",
    exits: dict.new(),
  )
}

fn npc_state(status: npc.NpcStatus) -> npc.State {
  npc.State(
    id: "goblin",
    name: "a goblin",
    pid: process.self(),
    subject: process.new_subject(),
    room: room_def(),
    status: status,
    tick_ms: 1000,
  )
}

fn target() -> npc.Target {
  npc.Target(pid: process.self(), name: "Alice")
}

fn joining(attempt: Int) -> log.Line {
  log.Line(woof.Debug, "joining room", [
    log.room("npc-room"),
    woof.int("attempt", attempt),
  ])
}

// ----- Ticking ----------------------------------------------------------

pub fn tick_while_alive_schedules_the_next_tick_without_losing_hp_test() {
  // Idle NPCs keep ticking so they are ready to attack when provoked, but
  // they no longer lose hp on their own.
  let state = npc_state(npc.Alive(3))
  let #(state, actions, logs) = npc.decide(state, npc.Tick(0))
  assert state.status == npc.Alive(3)
  assert actions == [npc.ScheduleTick(1000)]
  assert logs == [log.Line(woof.Debug, "ticked", [woof.int("hp", 3)])]
}

pub fn tick_while_attacking_hits_the_target_test() {
  let state = npc_state(npc.Attacking(3, target()))
  let #(state, actions, logs) = npc.decide(state, npc.Tick(0))
  assert state.status == npc.Attacking(3, target())
  assert actions
    == [
      npc.AttackPlayer(target(), combat.npc_damage),
      npc.ScheduleTick(1000),
    ]
  assert logs
    == [
      log.Line(woof.Debug, "ticked", [
        woof.int("hp", 3),
        woof.bool("hit", True),
      ]),
    ]
}

pub fn tick_while_attacking_misses_the_target_test() {
  let state = npc_state(npc.Attacking(3, target()))
  let #(state, actions, logs) = npc.decide(state, npc.Tick(99))
  assert state.status == npc.Attacking(3, target())
  assert actions == [npc.ScheduleTick(1000)]
  assert logs
    == [
      log.Line(woof.Debug, "ticked", [
        woof.int("hp", 3),
        woof.bool("hit", False),
      ]),
    ]
}

pub fn tick_when_dead_is_ignored_test() {
  let state = npc_state(npc.Dead)
  assert npc.decide(state, npc.Tick(0)) == #(state, [], [])
}

// ----- Entering ---------------------------------------------------------

pub fn enter_while_alive_joins_the_room_test() {
  let state = npc_state(npc.Alive(5))
  assert npc.decide(state, npc.Enter)
    == #(state, [npc.JoinRoom(0)], [joining(0)])
}

pub fn enter_while_attacking_joins_the_room_test() {
  let state = npc_state(npc.Attacking(5, target()))
  assert npc.decide(state, npc.Enter)
    == #(state, [npc.JoinRoom(0)], [joining(0)])
}

pub fn enter_when_dead_does_not_join_test() {
  let state = npc_state(npc.Dead)
  assert npc.decide(state, npc.Enter) == #(state, [], [])
}

// ----- Joining ----------------------------------------------------------

pub fn a_join_attempt_joins_the_room_test() {
  let state = npc_state(npc.Alive(5))
  assert npc.decide(state, npc.Join(3))
    == #(state, [npc.JoinRoom(3)], [joining(3)])
}

pub fn join_attempts_stop_after_the_limit_test() {
  // A room that never comes back must not be retried forever, and the give-up
  // is logged rather than silently dropped.
  let state = npc_state(npc.Alive(5))
  let #(_state, actions, logs) = npc.decide(state, npc.Join(11))
  assert actions == []
  assert logs
    == [
      log.Line(woof.Warning, "could not join room: gave up", [
        log.room("npc-room"),
        woof.int("attempt", 11),
      ]),
    ]
}

pub fn join_attempts_continue_up_to_the_limit_test() {
  let state = npc_state(npc.Alive(5))
  assert npc.decide(state, npc.Join(10))
    == #(state, [npc.JoinRoom(10)], [joining(10)])
}

pub fn join_when_dead_does_nothing_test() {
  let state = npc_state(npc.Dead)
  assert npc.decide(state, npc.Join(0)) == #(state, [], [])
}

// ----- Room down --------------------------------------------------------

pub fn room_down_rejoins_the_room_test() {
  // The room restarted: join it again so the NPC is not orphaned.
  let state = npc_state(npc.Alive(5))
  let message = npc.RoomDown(Some(process.self()))
  assert npc.decide(state, message)
    == #(state, [npc.JoinRoom(0)], [
      log.Line(woof.Warning, "room went down: rejoining", [log.room("npc-room")]),
    ])
}

pub fn room_down_while_attacking_rejoins_the_room_test() {
  let state = npc_state(npc.Attacking(5, target()))
  let message = npc.RoomDown(Some(process.self()))
  assert npc.decide(state, message)
    == #(state, [npc.JoinRoom(0)], [
      log.Line(woof.Warning, "room went down: rejoining", [log.room("npc-room")]),
    ])
}

pub fn room_down_when_dead_does_not_rejoin_test() {
  let state = npc_state(npc.Dead)
  let message = npc.RoomDown(Some(process.self()))
  assert npc.decide(state, message) == #(state, [], [])
}

pub fn room_down_of_a_port_is_ignored_test() {
  let state = npc_state(npc.Alive(5))
  assert npc.decide(state, npc.RoomDown(None)) == #(state, [], [])
}

// ----- Room events ------------------------------------------------------

pub fn room_messages_are_ignored_while_alive_test() {
  let state = npc_state(npc.Alive(5))
  let message = npc.RoomMessage(room.new_id("r1"), event.YouSaid("hi"))
  assert npc.decide(state, message) == #(state, [], [])
}

pub fn room_messages_are_ignored_when_dead_test() {
  let state = npc_state(npc.Dead)
  let message = npc.RoomMessage(room.new_id("r1"), event.YouSaid("hi"))
  assert npc.decide(state, message) == #(state, [], [])
}

// ----- Combat -----------------------------------------------------------

fn attacked(damage: Int) -> npc.Message {
  npc.RoomMessage(
    room.new_id("r1"),
    event.NpcAttacked("Alice", process.self(), damage),
  )
}

pub fn being_attacked_starts_attacking_and_targets_the_attacker_test() {
  let state = npc_state(npc.Alive(5))
  let #(state, actions, logs) = npc.decide(state, attacked(2))
  assert state.status == npc.Attacking(3, target())
  assert actions == []
  assert logs
    == [
      log.Line(woof.Info, "attacked", [
        woof.int("hp", 3),
        log.occupant_name("Alice"),
      ]),
    ]
}

pub fn a_missed_attack_still_provokes_the_npc_test() {
  let state = npc_state(npc.Alive(5))
  let #(state, actions, logs) = npc.decide(state, attacked(0))
  assert state.status == npc.Attacking(5, target())
  assert actions == []
  assert logs
    == [
      log.Line(woof.Info, "attacked", [
        woof.int("hp", 5),
        log.occupant_name("Alice"),
      ]),
    ]
}

pub fn being_attacked_again_retargets_and_keeps_hp_test() {
  let state = npc_state(npc.Attacking(4, target()))
  let #(state, actions, _logs) = npc.decide(state, attacked(1))
  assert state.status == npc.Attacking(3, target())
  assert actions == []
}

pub fn lethal_damage_kills_the_npc_test() {
  let state = npc_state(npc.Attacking(1, target()))
  let #(state, actions, logs) = npc.decide(state, attacked(2))
  assert state.status == npc.Dead
  assert actions == [npc.Die]
  assert logs == [log.Line(woof.Info, "died", [])]
}

pub fn a_dead_npc_ignores_further_attacks_test() {
  let state = npc_state(npc.Dead)
  assert npc.decide(state, attacked(1)) == #(state, [], [])
}

pub fn target_gone_returns_to_idling_test() {
  let state = npc_state(npc.Attacking(4, target()))
  let message = npc.RoomMessage(room.new_id("r1"), event.NpcTargetGone)
  let #(state, actions, logs) = npc.decide(state, message)
  assert state.status == npc.Alive(4)
  assert actions == []
  assert logs == [log.Line(woof.Debug, "attack target gone", [])]
}

pub fn target_gone_while_idling_is_ignored_test() {
  let state = npc_state(npc.Alive(4))
  let message = npc.RoomMessage(room.new_id("r1"), event.NpcTargetGone)
  assert npc.decide(state, message) == #(state, [], [])
}

// ----- The room's handle on the NPC -------------------------------------

pub fn to_occupant_is_an_npc_that_forwards_room_events_test() {
  let subject = process.new_subject()
  let state = npc.State(..npc_state(npc.Alive(5)), subject: subject)
  let occupant = npc.to_occupant(state, process.self())

  assert occupant.name == "a goblin"
  assert occupant.pid == process.self()
  assert occupant.kind == event.Npc

  let room.Occupant(listener: room.Listener(tell), ..) = occupant
  tell(room.new_id("r1"), event.YouSaid("hi"))

  let assert Ok(npc.RoomMessage(room_id, event.YouSaid("hi"))) =
    process.receive(subject, 10)
  assert room.id_to_string(room_id) == "r1"
}

// ----- The actor boundary -----------------------------------------------

pub fn a_dead_npc_is_finished_test() {
  // Death is final: the supervisor restarts a child only on an abnormal exit,
  // so a normally-stopped actor is not respawned.
  assert npc.is_finished(npc_state(npc.Dead))
}

pub fn a_live_npc_is_not_finished_test() {
  assert !npc.is_finished(npc_state(npc.Alive(5)))
}

pub fn an_attacking_npc_is_not_finished_test() {
  assert !npc.is_finished(npc_state(npc.Attacking(5, target())))
}
