//// Small helpers so every process spells the same log fields the same way,
//// plus the one data type a pure function uses to describe a log line.
////
//// `decide` returns `List(log.Line)`; the actor that owns the state calls
//// `log.emit` to actually write them.
////
//// Logging conventions:
////
//// - Messages are lowercase verb phrases with no trailing period:
////   `player entered room`, `connection opened`, `send failed, disconnecting`.
//// - A message is a stable key: no ids, names, counts or other variable data
////   in the string, all of that belongs in fields.
//// - The subject is dropped when the namespace already says it: the `player`
////   namespace logs `joining` / `looked` / `said`, the `room` namespace logs
////   `player entered room`.
//// - Failures say what could not happen, with the reason in a field:
////   `player could not join: no such room`.

import gleam/erlang/process
import woof

/// One field of a log line: a stable key and a typed value.
pub type Field =
  #(String, woof.FieldValue)

// ----- Pids -------------------------------------------------------------

/// Render a pid as Erlang writes it, e.g. `"<0.42.0>"`.
pub fn pid_to_string(pid: process.Pid) -> String {
  pid
  |> pid_to_charlist
  |> charlist_to_string
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_charlist(pid: process.Pid) -> List(Int)

@external(erlang, "erlang", "list_to_binary")
fn charlist_to_string(codepoints: List(Int)) -> String

// ----- Fields -----------------------------------------------------------

/// The `pid` field. Use it where the pid is the subject of the event.
pub fn pid(pid: process.Pid) -> Field {
  woof.str("pid", pid_to_string(pid))
}

/// The `player_pid` field. Use it when a pid identifies a *player* from
/// another process' point of view (room, world, server).
pub fn player_pid(pid: process.Pid) -> Field {
  woof.str("player_pid", pid_to_string(pid))
}

/// The `player_name` field, as the player typed it or as normalised (world).
pub fn player_name(name: String) -> Field {
  woof.str("player_name", name)
}

/// The `room` field: a room id, never a display name.
pub fn room(id: String) -> Field {
  woof.str("room", id)
}

/// A `*_count` field. Keep the key stable (`occupants_count`,
/// `players_count`, ...): that is what a dashboard or an alert groups by.
fn count(key: String, value: Int) -> Field {
  woof.int(key, value)
}

// ----- Loggers ----------------------------------------------------------

/// Logger for a room actor, carrying the room id and its occupancy.
///
/// The occupancy is the value *before* the message is applied.
pub fn room_logger(id: String, occupants: Int) -> woof.Logger {
  woof.new("room")
  |> woof.set_context([room(id), count("occupants_count", occupants)])
}

/// Logger for the world directory, carrying its room and player totals.
pub fn world_logger(rooms: Int, players: Int) -> woof.Logger {
  woof.new("world")
  |> woof.set_context([
    count("rooms_count", rooms),
    count("players_count", players),
  ])
}

/// Logger for one connection, carrying its session status and any further
/// context the caller has (name, pid, room) as it becomes known.
pub fn player_logger(
  session_status: String,
  context: List(Field),
) -> woof.Logger {
  woof.new("player")
  |> woof.set_context([woof.str("status", session_status), ..context])
}

// ----- Lines ------------------------------------------------------------

/// A log line described as data, so a pure `decide` can say what it wants
/// logged without logging it, and a test can assert on it without a sink.
pub type Line {
  Line(level: woof.Level, message: String, fields: List(Field))
}

/// Emit a line through a logger. Call this from an actor boundary.
pub fn emit(logger: woof.Logger, line: Line) -> Nil {
  let Line(level:, message:, fields:) = line
  logger |> woof.log(level, message, fields)
}
