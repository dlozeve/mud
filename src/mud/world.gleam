import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import mud/direction.{type Direction}
import mud/id.{type PlayerId, type RoomId}
import mud/room

// ----- State ------------------------------------------------------------

pub type State {
  State(rooms: Dict(RoomId, room.Def), players: Dict(PlayerId, process.Pid))
}

// ----- Message ----------------------------------------------------------

pub type Message {
  Join(player: PlayerId, pid: process.Pid, at: RoomId, reply_to: Subject(Reply))
  Move(from: RoomId, dir: Direction, reply_to: Subject(Reply))
  Down(pid: Option(process.Pid))
}

pub type Reply {
  Joined(Result(room.Def, JoinError))
  Moved(from: RoomId, result: Result(room.Def, MoveError))
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
  JoinReply(player: PlayerId, reply_to: Subject(Reply), result: Reply)
  MoveReply(reply_to: Subject(Reply), result: Reply)
  Monitor(pid: process.Pid)
}

// ----- Logic ------------------------------------------------------------

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Join(player, pid, at, reply_to) ->
      case dict.get(state.rooms, at), dict.get(state.players, player) {
        Ok(room), Error(_) -> {
          let new_state =
            State(..state, players: dict.insert(state.players, player, pid))
          let actions = [
            JoinReply(player: player, reply_to:, result: Joined(Ok(room))),
            Monitor(pid),
          ]
          #(new_state, actions)
        }
        _, Ok(_) -> #(state, [
          JoinReply(player:, reply_to:, result: Joined(Error(AlreadyLoggedIn))),
        ])
        Error(_), _ -> #(state, [
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
    Down(Some(pid)) -> {
      let players = dict.filter(state.players, fn(_, p) { p != pid })
      #(State(..state, players:), [])
    }
    Down(None) -> #(state, [])
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
  player: PlayerId,
  pid: process.Pid,
  at: RoomId,
  reply_to: Subject(Reply),
) -> Nil {
  case process.named(world) {
    Ok(_pid) ->
      actor.send(
        process.named_subject(world),
        Join(player:, pid:, at:, reply_to:),
      )
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
