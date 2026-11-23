import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import mud/combat
import mud/event
import mud/log
import mud/room
import woof

// A crashed room's supervisor restarts it, but its name may not be registered
// yet when the DOWN arrives, so joining is retried a bounded number of times.
const max_join_attempts = 10

const join_retry_ms = 1000

// What the map file says about an NPC: the room it starts in, how it
// presents itself, and its starting hp. The id names the actor's process and
// tags its log lines.
pub type Def {
  Def(id: String, name: String, room: room.Def, hp: Int)
}

pub type State {
  State(
    id: String,
    name: String,
    pid: process.Pid,
    subject: Subject(Message),
    room: room.Def,
    status: NpcStatus,
    tick_ms: Int,
  )
}

pub type NpcStatus {
  Alive(hp: Int)
  Attacking(hp: Int, target: Target)
  Dead
}

pub type Target {
  Target(pid: process.Pid, name: String)
}

pub type Message {
  // The roll is produced at the actor boundary so `decide` stays pure.
  Tick(roll: Int)
  Enter
  Join(attempt: Int)
  RoomMessage(room: room.Id, event: event.RoomEvent)
  RoomDown(pid: Option(process.Pid))
}

pub type Action {
  ScheduleTick(tick_ms: Int)
  JoinRoom(attempt: Int)
  AttackPlayer(target: Target, damage: Int)
  Die
}

pub fn decide(
  state: State,
  message: Message,
) -> #(State, List(Action), List(log.Line)) {
  case message {
    Tick(roll) ->
      case state.status {
        Dead -> #(state, [], [])
        Alive(hp) -> #(state, [ScheduleTick(state.tick_ms)], [
          log.Line(woof.Debug, "ticked", [woof.int("hp", hp)]),
        ])
        Attacking(hp, target) -> {
          let attack_outcome = combat.npc_hits(roll)
          let attack = case attack_outcome {
            combat.Hit -> [AttackPlayer(target, combat.npc_damage)]
            combat.Miss -> []
          }
          #(state, list.append(attack, [ScheduleTick(state.tick_ms)]), [
            log.Line(woof.Debug, "ticked", [
              woof.int("hp", hp),
              woof.str("outcome", combat.outcome_to_string(attack_outcome)),
            ]),
          ])
        }
      }
    Enter ->
      case is_alive(state.status) {
        True -> #(state, [JoinRoom(0)], [joining(state, 0)])
        False -> #(state, [], [])
      }
    Join(attempt) ->
      case is_alive(state.status) {
        True if attempt > max_join_attempts -> #(state, [], [
          log.Line(woof.Warning, "could not join room: gave up", [
            log.room(room.id_to_string(state.room.id)),
            woof.int("attempt", attempt),
          ]),
        ])
        True -> #(state, [JoinRoom(attempt)], [joining(state, attempt)])
        False -> #(state, [], [])
      }
    RoomMessage(_room, room_event) -> decide_room_event(state, room_event)
    RoomDown(Some(_pid)) ->
      case is_alive(state.status) {
        True -> #(state, [JoinRoom(0)], [
          log.Line(woof.Warning, "room went down: rejoining", [
            log.room(room.id_to_string(state.room.id)),
          ]),
        ])
        False -> #(state, [], [])
      }
    RoomDown(None) -> #(state, [], [])
  }
}

fn decide_room_event(
  state: State,
  room_event: event.RoomEvent,
) -> #(State, List(Action), List(log.Line)) {
  case state.status {
    // A dead NPC has nothing left to react to.
    Dead -> #(state, [], [])
    Alive(_) | Attacking(..) -> decide_live_room_event(state, room_event)
  }
}

fn decide_live_room_event(
  state: State,
  room_event: event.RoomEvent,
) -> #(State, List(Action), List(log.Line)) {
  case room_event {
    event.NpcAttacked(attacker_name, attacker_pid, damage) -> {
      let hp = case state.status {
        Alive(hp) | Attacking(hp, _) -> hp
        Dead -> 0
      }
      let hp = hp - damage
      case hp <= 0 {
        True -> #(State(..state, status: Dead), [Die], [
          log.Line(woof.Info, "died", []),
        ])
        False -> #(
          State(
            ..state,
            status: Attacking(
              hp,
              Target(pid: attacker_pid, name: attacker_name),
            ),
          ),
          [],
          [
            log.Line(woof.Info, "attacked", [
              woof.int("hp", hp),
              log.occupant_name(attacker_name),
            ]),
          ],
        )
      }
    }
    // The target left the room or died: go back to idling.
    event.NpcTargetGone ->
      case state.status {
        Attacking(hp, _) -> #(State(..state, status: Alive(hp)), [], [
          log.Line(woof.Debug, "attack target gone", []),
        ])
        Alive(_) | Dead -> #(state, [], [])
      }
    // Everything else is not addressed to an NPC.
    event.YouAreIn(..)
    | event.OccupantArrived(..)
    | event.OccupantLeft(..)
    | event.OccupantDied(..)
    | event.YouSaid(..)
    | event.OccupantSaid(..)
    | event.OccupantList(..)
    | event.AttackFailed(..)
    | event.YouHitNpc(..)
    | event.YouMissedNpc(..)
    | event.NpcHitYou(..) -> #(state, [], [])
  }
}

fn is_alive(status: NpcStatus) -> Bool {
  case status {
    Dead -> False
    Alive(_) | Attacking(..) -> True
  }
}

fn joining(state: State, attempt: Int) -> log.Line {
  log.Line(woof.Debug, "joining room", [
    log.room(room.id_to_string(state.room.id)),
    woof.int("attempt", attempt),
  ])
}

fn run(action: Action, state: State) -> Nil {
  case action {
    ScheduleTick(tick_ms:) -> schedule_tick(state.subject, tick_ms)
    JoinRoom(attempt:) -> join(state, attempt)
    AttackPlayer(target, damage) -> {
      let _ =
        room.npc_attack(
          state.room.process_name,
          state.pid,
          target.pid,
          state.name,
          damage,
        )
      Nil
    }
    Die -> {
      let _ = room.died(state.room.process_name, state.pid)
      Nil
    }
  }
}

// Joining also monitors the room, so a room that goes down sends a DOWN and
// the NPC can rejoin the replacement rather than being left orphaned.
fn join(state: State, attempt: Int) -> Nil {
  case process.named(state.room.process_name) {
    Ok(room_pid) -> {
      let _ = process.monitor(room_pid)
      let _ = room.enter(state.room.process_name, to_occupant(state, state.pid))
      Nil
    }
    Error(_) -> {
      // The room is not up yet: retry shortly, which also logs the attempt.
      let _ =
        process.send_after(state.subject, join_retry_ms, Join(attempt + 1))
      Nil
    }
  }
}

fn schedule_tick(subject: Subject(Message), tick_ms: Int) -> Nil {
  let _ = process.send_after(subject, tick_ms, Tick(combat.roll()))
  Nil
}

/// Whether the actor should stop: a dead NPC leaves the room and is done.
///
/// The supervisor restarts an NPC only on an abnormal exit, so a normal stop
/// is final until respawning is designed.
pub fn is_finished(state: State) -> Bool {
  case state.status {
    Dead -> True
    Alive(_) | Attacking(..) -> False
  }
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let logger = log.npc_logger(state.id, state.name, state.pid)
  let #(state, actions, logs) = decide(state, message)
  list.each(logs, log.emit(logger, _))
  list.each(actions, run(_, state))
  case is_finished(state) {
    True -> actor.stop()
    False -> actor.continue(state)
  }
}

pub fn to_occupant(state: State, pid: process.Pid) -> room.Occupant {
  room.occupant(state.name, pid, event.Npc, fn(room_id, room_event) {
    process.send(state.subject, RoomMessage(room_id, room_event))
  })
}
