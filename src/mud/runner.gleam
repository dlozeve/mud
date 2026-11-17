import gleam/erlang/process
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/string
import mud/player
import mud/room
import mud/session
import mud/world

// ----- Effects ----------------------------------------------------------

pub type StopReason(reason) {
  SendFailed(reason)
  Requested
}

// Writes one line to the client. The error is transport-specific: the server
// passes the socket error, tests pass Nil.
pub type Sender(reason) =
  fn(String) -> Result(Nil, reason)

// Schedules a message back to the session after a delay. The default uses a
// real timer; tests record the schedule instead of waiting for it.
pub type Scheduler =
  fn(process.Subject(session.Message), Int, session.Message) -> Nil

// ----- Execution --------------------------------------------------------

pub fn process_scheduler(
  subject: process.Subject(session.Message),
  delay: Int,
  message: session.Message,
) -> Nil {
  let _ = process.send_after(subject, delay, message)
  Nil
}

pub fn run_effects(
  state: session.State,
  send: Sender(reason),
  effects: List(session.Effect),
) -> Result(session.State, StopReason(reason)) {
  run_effects_with(state, send, process_scheduler, effects)
}

pub fn run_effects_with(
  state: session.State,
  send: Sender(reason),
  schedule: Scheduler,
  effects: List(session.Effect),
) -> Result(session.State, StopReason(reason)) {
  case effects {
    [] -> Ok(state)
    [session.Stop, ..] -> Error(Requested)
    [session.Join(to_room_id), ..rest] ->
      case state.status {
        session.Joining(player_name) -> {
          world.join(
            state.world,
            player_name,
            process.self(),
            to_room_id,
            state.replies,
          )
          schedule(state.subject, 5000, session.JoinTimeout)
          run_effects_with(state, send, schedule, rest)
        }
        // A join request is only meaningful while a name is being claimed.
        session.AwaitingName | session.InGame(_) -> {
          skip_effect("a join request outside the Joining state")
          run_effects_with(state, send, schedule, rest)
        }
      }
    [session.EnterRoom(to_room, attempt), ..rest] ->
      case state.status, process.named(to_room.process_name) {
        session.InGame(player), Ok(pid) -> {
          case state.room_watch {
            Some(session.RoomWatch(_pid, monitor)) ->
              process.demonitor_process(monitor)
            None -> Nil
          }
          room.enter(to_room.process_name, session.to_occupant(state, player))
          let room_watch =
            Some(session.RoomWatch(pid: pid, monitor: process.monitor(pid)))
          run_effects_with(
            session.State(..state, room_watch:),
            send,
            schedule,
            rest,
          )
        }
        session.InGame(_), Error(_) -> {
          schedule(state.subject, 100, session.RetryEnter(to_room, attempt + 1))
          run_effects_with(state, send, schedule, rest)
        }
        _, _ -> run_effects_with(state, send, schedule, rest)
      }
    [session.LeaveRoom(room_name), ..rest] ->
      case state.status {
        session.InGame(player_state) -> {
          room.leave(room_name, player_state.pid)
          run_effects_with(state, send, schedule, rest)
        }
        _ -> run_effects_with(state, send, schedule, rest)
      }
    [session.Do(action), ..rest] ->
      case run_effect(state, send, action) {
        Ok(new_state) -> run_effects_with(new_state, send, schedule, rest)
        Error(e) -> Error(e)
      }
  }
}

fn run_effect(
  state: session.State,
  send: Sender(reason),
  action: player.Action,
) -> Result(session.State, StopReason(reason)) {
  case action {
    player.Output(text) -> write(state, send, text)
    player.Say(line) ->
      with_player(state, action, fn(player) {
        room.say(player.room.process_name, player.pid, line)
        Ok(state)
      })
    player.Move(dir) ->
      with_player(state, action, fn(player) {
        case world.move(state.world, player.room.id, dir, state.replies) {
          Ok(_) -> Ok(state)
          Error(_) -> write(state, send, "The world is restarting, try again.")
        }
      })
    player.Look ->
      with_player(state, action, fn(player) {
        room.look(player.room.process_name, player.pid)
        Ok(state)
      })
  }
}

fn with_player(
  state: session.State,
  action: player.Action,
  perform: fn(player.State) -> Result(session.State, StopReason(reason)),
) -> Result(session.State, StopReason(reason)) {
  case current_player(state) {
    Some(player) -> perform(player)
    None -> skip_playerless_effect(state, action)
  }
}

// An effect that needs a player was produced for a session that is not in the game.
fn skip_playerless_effect(
  state: session.State,
  action: player.Action,
) -> Result(session.State, StopReason(reason)) {
  skip_effect(string.inspect(action) <> " with no player in the session")
  Ok(state)
}

fn skip_effect(reason: String) -> Nil {
  // TODO: replace with the `logging` package
  io.println_error("skipping " <> reason)
}

fn write(
  state: session.State,
  send: Sender(reason),
  text: String,
) -> Result(session.State, StopReason(reason)) {
  case send(text <> "\n") {
    Ok(_) -> Ok(state)
    Error(reason) -> Error(SendFailed(reason))
  }
}

fn current_player(state: session.State) -> Option(player.State) {
  case state.status {
    session.AwaitingName -> None
    session.Joining(_) -> None
    session.InGame(player) -> Some(player)
  }
}
