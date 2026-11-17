import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import mud/direction.{type Direction}
import mud/room

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
  Move(from: room.Id, dir: Direction, reply_to: Subject(Reply))
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

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Join(name, pid, at, reply_to) -> {
      // Names are compared case-insensitively, so "Alice" and "alice" are the
      // same player as far as the game is concerned.
      let name = string.lowercase(name)
      case dict.get(state.rooms, at), dict.get(state.players, name) {
        Error(_), _ -> #(state, [
          JoinReply(reply_to, Joined(Error(NoSuchRoom))),
        ])
        Ok(_), Ok(_) -> #(state, [
          JoinReply(reply_to, Joined(Error(AlreadyLoggedIn))),
        ])
        Ok(room), Error(_) -> #(
          State(..state, players: dict.insert(state.players, name, pid)),
          [JoinReply(reply_to, Joined(Ok(room))), Monitor(pid)],
        )
      }
    }
    Move(from, dir, reply_to) ->
      case resolve_direction(state.rooms, from, dir) {
        Ok(to_room) -> #(state, [
          MoveReply(reply_to, Moved(from:, result: Ok(to_room))),
        ])
        Error(error) -> #(state, [
          MoveReply(reply_to, Moved(from:, result: Error(error))),
        ])
      }
    Down(Some(pid)) -> {
      let players = dict.filter(state.players, fn(_, p) { p != pid })
      #(State(..state, players:), [])
    }
    Down(None) -> #(state, [])
  }
}

fn resolve_direction(
  rooms: Dict(room.Id, room.Def),
  at: room.Id,
  dir: Direction,
) -> Result(room.Def, MoveError) {
  case dict.get(rooms, at) {
    Ok(from_room) ->
      case dict.get(from_room.exits, dir) {
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
  let #(state, actions) = decide(state, message)
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
) -> Nil {
  case process.named(world) {
    Ok(_pid) ->
      actor.send(
        process.named_subject(world),
        Join(name:, pid:, at:, reply_to:),
      )
    Error(_) -> Nil
  }
}

pub fn move(
  world: process.Name(Message),
  from: room.Id,
  dir: Direction,
  reply_to: Subject(Reply),
) -> Result(Nil, Nil) {
  case process.named(world) {
    Ok(_pid) ->
      actor.send(process.named_subject(world), Move(from:, dir:, reply_to:))
      |> Ok
    Error(_) -> Error(Nil)
  }
}
