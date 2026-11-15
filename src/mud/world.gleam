import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import mud/direction.{type Direction}
import mud/id.{type PlayerId, type RoomId}
import mud/room

// ----- State ------------------------------------------------------------

pub type State {
  State(rooms: Dict(RoomId, room.Def))
}

// ----- Message ----------------------------------------------------------

pub type Message {
  Join(player: PlayerId, at: RoomId, reply_to: Subject(Reply))
  Move(from: RoomId, dir: Direction, reply_to: Subject(Reply))
}

pub type Reply {
  Joined(Result(room.Def, JoinError))
  Moved(from: RoomId, result: Result(room.Def, MoveError))
}

pub type JoinError {
  NoSuchRoom
  NameTaken
}

pub type MoveError {
  NonExistingRoom
  NonExistingExit
}

// ----- Action -----------------------------------------------------------

pub type Action {
  JoinReply(player: PlayerId, reply_to: Subject(Reply), result: Reply)
  MoveReply(reply_to: Subject(Reply), result: Reply)
}

// ----- Logic ------------------------------------------------------------

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Join(player, at, reply_to) ->
      // TODO: check that the name isn't already taken
      case dict.get(state.rooms, at) {
        Ok(room) -> #(state, [
          JoinReply(player:, reply_to:, result: Joined(Ok(room))),
        ])
        Error(_) -> #(state, [
          JoinReply(player:, reply_to:, result: Joined(Error(NoSuchRoom))),
        ])
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
  }
}

fn resolve_direction(
  rooms: Dict(RoomId, room.Def),
  at: RoomId,
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
    JoinReply(_player, reply_to, result) -> actor.send(reply_to, result)
    MoveReply(reply_to, result) -> actor.send(reply_to, result)
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
  player: PlayerId,
  at: RoomId,
  reply_to: Subject(Reply),
) -> Nil {
  case process.named(world) {
    Ok(_pid) ->
      actor.send(process.named_subject(world), Join(player:, at:, reply_to:))
    Error(_) -> Nil
  }
}

pub fn move(
  world: process.Name(Message),
  from: RoomId,
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
