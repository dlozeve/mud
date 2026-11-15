import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import mud/direction.{type Direction}
import mud/id.{type RoomId}
import mud/room

// ----- State ------------------------------------------------------------

pub type State {
  State(rooms: Dict(RoomId, RoomInfo))
}

pub type RoomInfo {
  RoomInfo(
    process_name: process.Name(room.Message),
    id: RoomId,
    name: String,
    description: String,
    exits: Dict(Direction, RoomId),
  )
}

// ----- Message ----------------------------------------------------------

pub type Message {
  Join(at: RoomId, reply_to: Subject(Result(RoomInfo, JoinError)))
  Move(
    from: RoomId,
    dir: Direction,
    reply_to: Subject(Result(RoomInfo, MoveError)),
  )
}

pub type JoinError {
  NoSuchRoom
}

pub type MoveError {
  NonExistingRoom
  NonExistingExit
}

// ----- Action -----------------------------------------------------------

pub type Action {
  JoinReply(
    reply_to: Subject(Result(RoomInfo, JoinError)),
    result: Result(RoomInfo, JoinError),
  )
  MoveReply(
    reply_to: Subject(Result(RoomInfo, MoveError)),
    result: Result(RoomInfo, MoveError),
  )
}

// ----- Logic ------------------------------------------------------------

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Join(at, reply_to) ->
      // TODO: check that the name isn't already taken
      case dict.get(state.rooms, at) {
        Ok(room) -> #(state, [JoinReply(reply_to, Ok(room))])
        Error(_) -> #(state, [JoinReply(reply_to, Error(NoSuchRoom))])
      }
    Move(from, dir, reply_to) ->
      case resolve_direction(state.rooms, from, dir) {
        Ok(to_room) -> #(state, [MoveReply(reply_to, Ok(to_room))])
        Error(error) -> #(state, [MoveReply(reply_to, Error(error))])
      }
  }
}

fn resolve_direction(
  rooms: Dict(RoomId, RoomInfo),
  at: RoomId,
  dir: Direction,
) -> Result(RoomInfo, MoveError) {
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
  world: Subject(Message),
  at: RoomId,
) -> Result(RoomInfo, JoinError) {
  actor.call(world, 1000, Join(at:, reply_to: _))
}

pub fn move(
  world: Subject(Message),
  from: RoomId,
  dir: Direction,
) -> Result(RoomInfo, MoveError) {
  actor.call(world, 1000, Move(from:, dir:, reply_to: _))
}
