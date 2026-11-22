import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
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
    name: "a goblin",
    pid: process.self(),
    subject: process.new_subject(),
    room: room_def(),
    status: status,
    tick_ms: 1000,
  )
}

fn joining(attempt: Int) -> log.Line {
  log.Line(woof.Debug, "joining room", [
    log.room("npc-room"),
    woof.int("attempt", attempt),
  ])
}

// ----- Ticking ----------------------------------------------------------

pub fn tick_while_alive_decrements_hp_and_says_test() {
  let state = npc_state(npc.Alive(3))
  let #(state, actions, logs) = npc.decide(state, npc.Tick)
  assert state.status == npc.Alive(2)
  assert actions == [npc.Say("I am alive!"), npc.ScheduleTick(1000)]
  assert logs == [log.Line(woof.Debug, "ticked", [woof.int("hp", 2)])]
}

pub fn tick_at_one_hp_schedules_the_death_tick_test() {
  // The hp > 0 branch is taken, so the last tick still schedules another one.
  // The next tick is the one that kills the NPC.
  let state = npc_state(npc.Alive(1))
  let #(state, actions, logs) = npc.decide(state, npc.Tick)
  assert state.status == npc.Alive(0)
  assert actions == [npc.Say("I am alive!"), npc.ScheduleTick(1000)]
  assert logs == [log.Line(woof.Debug, "ticked", [woof.int("hp", 0)])]
}

pub fn tick_at_zero_hp_dies_and_leaves_the_room_test() {
  let state = npc_state(npc.Alive(0))
  let #(state, actions, logs) = npc.decide(state, npc.Tick)
  assert state.status == npc.Dead
  assert actions == [npc.Say("I am dead"), npc.LeaveRoom]
  assert logs == [log.Line(woof.Info, "died", [])]
}

pub fn the_death_tick_does_not_schedule_another_tick_test() {
  // The tick chain ends here: nothing in the death actions reschedules, so a
  // dead NPC cannot tick itself back to life.
  let #(_state, actions, _logs) = npc.decide(npc_state(npc.Alive(0)), npc.Tick)
  assert !list_has_schedule_tick(actions)
}

pub fn tick_when_dead_is_ignored_test() {
  let state = npc_state(npc.Dead)
  assert npc.decide(state, npc.Tick) == #(state, [], [])
}

fn list_has_schedule_tick(actions: List(npc.Action)) -> Bool {
  case actions {
    [] -> False
    [npc.ScheduleTick(_), ..] -> True
    [_, ..rest] -> list_has_schedule_tick(rest)
  }
}

// ----- Entering ---------------------------------------------------------

pub fn enter_while_alive_joins_the_room_test() {
  let state = npc_state(npc.Alive(5))
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
