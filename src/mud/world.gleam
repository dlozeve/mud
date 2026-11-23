import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import mud/direction.{type Direction}
import mud/log
import mud/room
import woof

// ----- State ------------------------------------------------------------

pub type State {
  // The directory is keyed by the normalised player name: names are what have
  // to be unique, while player ids are opaque handles minted per connection and
  // shared with the rooms, not with this catalog.
  State(rooms: Dict(room.Id, room.Def), players: Dict(String, process.Pid))
}

// ----- Message ----------------------------------------------------------

pub type Message {
  Join(name: String, pid: process.Pid, at: room.Id, reply_to: Subject(Reply))
  Move(from: room.Id, direction: Direction, reply_to: Subject(Reply))
  Down(pid: Option(process.Pid))
}

pub type Reply {
  Joined(Result(room.Def, JoinError))
  Moved(from: room.Id, result: Result(room.Def, MoveError))
}

pub type JoinError {
  NoSuchRoom
  AlreadyLoggedIn
}

pub type MoveError {
  NonExistingRoom
  NonExistingExit
}

// ----- Action -----------------------------------------------------------

pub type Action {
  JoinReply(reply_to: Subject(Reply), result: Reply)
  MoveReply(reply_to: Subject(Reply), result: Reply)
  Monitor(pid: process.Pid)
}

// ----- Logic ------------------------------------------------------------

pub fn decide(
  state: State,
  message: Message,
) -> #(State, List(Action), List(log.Line)) {
  case message {
    Join(name, pid, at, reply_to) -> {
      // Names are compared case-insensitively, so "Alice" and "alice" are the
      // same player as far as the game is concerned.
      let name = string.lowercase(name)
      case dict.get(state.rooms, at), dict.get(state.players, name) {
        Error(_), _ -> {
          let logs = [
            log.Line(woof.Warning, "player could not join: no such room", [
              log.occupant_name(name),
              log.occupant_pid(pid),
              log.room(room.id_to_string(at)),
            ]),
          ]
          #(state, [JoinReply(reply_to, Joined(Error(NoSuchRoom)))], logs)
        }
        Ok(_), Ok(_) -> {
          let logs = [
            log.Line(woof.Warning, "player could not join: already logged in", [
              log.occupant_name(name),
              log.occupant_pid(pid),
              log.room(room.id_to_string(at)),
            ]),
          ]
          #(state, [JoinReply(reply_to, Joined(Error(AlreadyLoggedIn)))], logs)
        }
        Ok(room), Error(_) -> {
          let logs = [
            log.Line(woof.Debug, "player joining", [
              log.occupant_name(name),
              log.occupant_pid(pid),
              log.room(room.id_to_string(room.id)),
            ]),
          ]
          #(
            State(..state, players: dict.insert(state.players, name, pid)),
            [JoinReply(reply_to, Joined(Ok(room))), Monitor(pid)],
            logs,
          )
        }
      }
    }
    Move(from, direction, reply_to) ->
      case resolve_direction(state.rooms, from, direction) {
        Ok(to_room) -> {
          let logs = [
            log.Line(woof.Debug, "player moving", [
              woof.str("from_room", room.id_to_string(from)),
              woof.str("direction", direction.render(direction)),
              woof.str("to_room", room.id_to_string(to_room.id)),
            ]),
          ]
          #(
            state,
            [MoveReply(reply_to, Moved(from:, result: Ok(to_room)))],
            logs,
          )
        }
        Error(error) -> {
          let logs = [
            log.Line(woof.Warning, "player could not move", [
              woof.str("from_room", room.id_to_string(from)),
              woof.str("direction", direction.render(direction)),
              woof.str("error", string.inspect(error)),
            ]),
          ]
          #(
            state,
            [MoveReply(reply_to, Moved(from:, result: Error(error)))],
            logs,
          )
        }
      }
    Down(Some(pid)) -> {
      let players = dict.filter(state.players, fn(_, p) { p != pid })
      let logs = [
        log.Line(woof.Debug, "player process down", [log.occupant_pid(pid)]),
      ]
      #(State(..state, players:), [], logs)
    }
    Down(None) -> #(state, [], [])
  }
}

fn resolve_direction(
  rooms: Dict(room.Id, room.Def),
  at: room.Id,
  direction: Direction,
) -> Result(room.Def, MoveError) {
  case dict.get(rooms, at) {
    Ok(from_room) ->
      case dict.get(from_room.exits, direction) {
        Ok(to) ->
          case dict.get(rooms, to) {
            Ok(to_room) -> Ok(to_room)
            Error(_) -> Error(NonExistingRoom)
          }
        Error(_) -> Error(NonExistingExit)
      }
    Error(_) -> Error(NonExistingRoom)
  }
}

// ----- Execution --------------------------------------------------------

fn run(action: Action) -> Nil {
  case action {
    JoinReply(reply_to, result) -> actor.send(reply_to, result)
    MoveReply(reply_to, result) -> actor.send(reply_to, result)
    Monitor(pid) -> {
      let _ = process.monitor(pid)
      Nil
    }
  }
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let logger =
    log.world_logger(dict.size(state.rooms), dict.size(state.players))
  let #(state, actions, logs) = decide(state, message)
  list.each(logs, log.emit(logger, _))
  list.each(actions, run)
  actor.continue(state)
}

// ------ Public helpers --------------------------------------------------

pub fn join(
  world: process.Name(Message),
  name: String,
  pid: process.Pid,
  at: room.Id,
  reply_to: Subject(Reply),
) -> Result(Nil, Nil) {
  case process.named(world) {
    Ok(_pid) ->
      actor.send(
        process.named_subject(world),
        Join(name:, pid:, at:, reply_to:),
      )
      |> Ok
    Error(_) -> Error(Nil)
  }
}

pub fn move(
  world: process.Name(Message),
  from: room.Id,
  direction: Direction,
  reply_to: Subject(Reply),
) -> Result(Nil, Nil) {
  case process.named(world) {
    Ok(_pid) ->
      actor.send(
        process.named_subject(world),
        Move(from:, direction:, reply_to:),
      )
      |> Ok
    Error(_) -> Error(Nil)
  }
}
