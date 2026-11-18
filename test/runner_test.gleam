import gleam/dict
import gleam/erlang/process
import gleam/option.{None}
import mud/player
import mud/room
import mud/runner
import mud/session

// ----- Helpers ----------------------------------------------------------

fn room_def(name: String) -> room.Def {
  room.Def(
    process_name: process.new_name(name),
    id: room.new_id(name),
    name: name,
    description: name <> " description",
    exits: dict.new(),
  )
}

fn state_with(status: session.Status) -> session.State {
  session.State(
    subject: process.new_subject(),
    replies: process.new_subject(),
    world: process.new_name("world"),
    entrance: room.new_id("entrance"),
    status: status,
    buffer: <<>>,
    room_watch: None,
  )
}

fn player_in(room: room.Def) -> player.State {
  player.State(pid: process.self(), name: "Alice", room: room)
}

fn recording_sender(subject: process.Subject(String)) -> runner.Sender(Nil) {
  fn(text) {
    process.send(subject, text)
    Ok(Nil)
  }
}

fn recording_scheduler(
  subject: process.Subject(#(Int, session.Message)),
) -> runner.Scheduler {
  fn(_target, delay, message) {
    process.send(subject, #(delay, message))
    Nil
  }
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

// ----- Ordering ---------------------------------------------------------

pub fn effects_run_in_order_test() {
  let state = state_with(session.AwaitingName)
  let sent = process.new_subject()
  let scheduled = process.new_subject()

  let result =
    runner.run_effects_with(
      state,
      recording_sender(sent),
      recording_scheduler(scheduled),
      [
        session.Do(player.Output("first")),
        session.Do(player.Output("second")),
      ],
    )

  assert is_ok(result)
  assert process.receive(sent, 100) == Ok("first\n")
  assert process.receive(sent, 100) == Ok("second\n")
  assert process.receive(sent, 100) == Error(Nil)
  assert process.receive(scheduled, 100) == Error(Nil)
}

pub fn stop_halts_later_effects_test() {
  let state = state_with(session.AwaitingName)
  let sent = process.new_subject()
  let scheduled = process.new_subject()

  let result =
    runner.run_effects_with(
      state,
      recording_sender(sent),
      recording_scheduler(scheduled),
      [
        session.Do(player.Output("before")),
        session.Stop,
        session.Do(player.Output("after")),
      ],
    )

  assert case result {
    Error(runner.Requested) -> True
    _ -> False
  }
  assert process.receive(sent, 100) == Ok("before\n")
  assert process.receive(sent, 100) == Error(Nil)
}

pub fn failed_send_halts_later_effects_test() {
  let state = state_with(session.AwaitingName)
  let attempts = process.new_subject()
  let scheduled = process.new_subject()
  let send = fn(text: String) -> Result(Nil, String) {
    process.send(attempts, text)
    Error("closed")
  }

  let result =
    runner.run_effects_with(state, send, recording_scheduler(scheduled), [
      session.Do(player.Output("first")),
      session.Do(player.Output("second")),
    ])

  assert case result {
    Error(runner.SendFailed("closed")) -> True
    _ -> False
  }
  assert process.receive(attempts, 100) == Ok("first\n")
  assert process.receive(attempts, 100) == Error(Nil)
}

// ----- Scheduling -------------------------------------------------------

pub fn join_schedules_a_timeout_test() {
  let state = state_with(session.Joining("Alice"))
  let sent = process.new_subject()
  let scheduled = process.new_subject()

  // The world is not registered, so the join request goes nowhere: the
  // timeout is the only thing that can rescue the session.
  let result =
    runner.run_effects_with(
      state,
      recording_sender(sent),
      recording_scheduler(scheduled),
      [
        session.Join(room.new_id("entrance")),
        session.Do(player.Output("after")),
      ],
    )

  assert is_ok(result)
  assert process.receive(scheduled, 100) == Ok(#(5000, session.JoinTimeout))
  assert process.receive(sent, 100) == Ok("after\n")
}

pub fn unavailable_room_schedules_retry_test() {
  let target_room = room_def("unavailable")
  let state = state_with(session.InGame(player_in(target_room)))
  let sent = process.new_subject()
  let scheduled = process.new_subject()

  let result =
    runner.run_effects_with(
      state,
      recording_sender(sent),
      recording_scheduler(scheduled),
      [
        session.EnterRoom(target_room, 0),
        session.Do(player.Output("after")),
      ],
    )

  assert is_ok(result)
  assert case process.receive(scheduled, 100) {
    Ok(#(100, session.RetryEnter(actual, 1))) -> actual.id == target_room.id
    _ -> False
  }
  assert process.receive(sent, 100) == Ok("after\n")
}
