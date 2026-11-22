import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import mud/event
import mud/log
import mud/room
import woof

// A crashed room's supervisor restarts it, but its name may not be registered
// yet when the DOWN arrives, so joining is retried a bounded number of times.
const max_join_attempts = 10

const join_retry_ms = 1000

pub type State {
  State(
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
  Dead
}

pub type Message {
  Tick
  Enter
  Join(attempt: Int)
  RoomMessage(room: room.Id, event: event.RoomEvent)
  RoomDown(pid: Option(process.Pid))
}

pub type Action {
  Say(String)
  ScheduleTick(tick_ms: Int)
  JoinRoom(attempt: Int)
  LeaveRoom
}

pub fn decide(
  state: State,
  message: Message,
) -> #(State, List(Action), List(log.Line)) {
  case message {
    Tick ->
      case state.status {
        // hp counts down towards zero; the tick after it reaches zero is the
        // death tick, so the NPC is not dead yet when hp hits 0.
        Alive(0) -> #(
          State(..state, status: Dead),
          [Say("I am dead"), LeaveRoom],
          [log.Line(woof.Info, "died", [])],
        )
        Alive(hp) -> #(
          State(..state, status: Alive(hp - 1)),
          [Say("I am alive!"), ScheduleTick(state.tick_ms)],
          [log.Line(woof.Debug, "ticked", [woof.int("hp", hp - 1)])],
        )
        Dead -> #(state, [], [])
      }
    Enter ->
      case state.status {
        Alive(_) -> #(state, [JoinRoom(0)], [joining(state, 0)])
        Dead -> #(state, [], [])
      }
    Join(attempt) ->
      case state.status {
        Alive(_) if attempt > max_join_attempts -> #(state, [], [
          log.Line(woof.Warning, "could not join room: gave up", [
            log.room(room.id_to_string(state.room.id)),
            woof.int("attempt", attempt),
          ]),
        ])
        Alive(_) -> #(state, [JoinRoom(attempt)], [joining(state, attempt)])
        Dead -> #(state, [], [])
      }
    RoomMessage(_room, _event) -> #(state, [], [])
    RoomDown(Some(_pid)) ->
      case state.status {
        Alive(_) -> #(state, [JoinRoom(0)], [
          log.Line(woof.Warning, "room went down: rejoining", [
            log.room(room.id_to_string(state.room.id)),
          ]),
        ])
        Dead -> #(state, [], [])
      }
    RoomDown(None) -> #(state, [], [])
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
    Say(text) -> room.say(state.room.process_name, state.pid, text)
    ScheduleTick(tick_ms:) -> schedule_tick(state.subject, tick_ms)
    JoinRoom(attempt:) -> join(state, attempt)
    LeaveRoom -> room.leave(state.room.process_name, state.pid)
  }
}

// Joining also monitors the room, so a room that goes down sends a DOWN and
// the NPC can rejoin the replacement rather than being left orphaned.
fn join(state: State, attempt: Int) -> Nil {
  case process.named(state.room.process_name) {
    Ok(room_pid) -> {
      let _ = process.monitor(room_pid)
      room.enter(state.room.process_name, to_occupant(state, state.pid))
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
  let _ = process.send_after(subject, tick_ms, Tick)
  Nil
}

/// Whether the actor should stop: a dead NPC leaves the room and is done.
///
/// The supervisor restarts an NPC only on an abnormal exit, so a normal stop
/// is final until respawning is designed.
pub fn is_finished(state: State) -> Bool {
  case state.status {
    Alive(_) -> False
    Dead -> True
  }
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let logger = log.npc_logger(state.name, state.pid)
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
