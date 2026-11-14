import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import mud/direction.{type Direction}
import mud/event
import mud/id.{type PlayerId, type RoomId}
import mud/room

pub type Message {
  Join(
    session: event.Session,
    at: RoomId,
    reply_to: Subject(Result(Nil, JoinError)),
  )
  Move(player: PlayerId, dir: Direction)
  Leave(player: PlayerId)
  PlayerSays(player: PlayerId, text: String)
  Look(player: PlayerId)
}

pub type JoinError {
  NameTaken
  NoSuchRoom
}

pub type RoomInfo {
  RoomInfo(
    subject: Subject(room.Message),
    id: RoomId,
    name: String,
    description: String,
    exits: Dict(Direction, RoomId),
  )
}

pub type Member {
  Member(session: event.Session, at: RoomId)
}

pub type State {
  // Rooms own occupancy. `members` is just an index over all the rooms `occupancy` maps.
  // Convergence is eventual.
  State(rooms: Dict(RoomId, RoomInfo), members: Dict(PlayerId, Member))
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let #(state, actions) = decide(state, message)
  list.each(actions, run)
  actor.continue(state)
}

pub type Action {
  DescribeRoom(
    session: event.Session,
    room_name: String,
    room_description: String,
    exits: List(Direction),
  )
  EnterRoom(session: event.Session, room: Subject(room.Message))
  LeaveRoom(player: PlayerId, room: Subject(room.Message))
  Say(player: PlayerId, room: Subject(room.Message), text: String)
  Reply(
    reply_to: Subject(Result(Nil, JoinError)),
    result: Result(Nil, JoinError),
  )
}

fn run(action: Action) -> Nil {
  case action {
    DescribeRoom(session, room_name, room_description, exits) ->
      session.listener.tell(event.YouAreIn(
        room_name:,
        room_description:,
        exits:,
      ))
    EnterRoom(session, room_subject) -> room.enter(room_subject, session)
    LeaveRoom(player, room_subject) -> room.leave(room_subject, player)
    Say(player_id, room_subject, text) ->
      room.say(room_subject, player_id, text)
    Reply(reply_to, result) -> actor.send(reply_to, result)
  }
}

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Join(session, at, reply_to) ->
      case dict.get(state.members, session.id), dict.get(state.rooms, at) {
        Ok(_), _ -> #(state, [Reply(reply_to, Error(NameTaken))])
        Error(_), Ok(room) -> {
          let actions = [
            Reply(reply_to, Ok(Nil)),
            DescribeRoom(
              session,
              room.name,
              room.description,
              dict.keys(room.exits),
            ),
            EnterRoom(session, room.subject),
          ]
          let new_state =
            State(
              ..state,
              members: dict.insert(
                state.members,
                session.id,
                Member(session, at),
              ),
            )
          #(new_state, actions)
        }
        Error(_), Error(_) -> #(state, [Reply(reply_to, Error(NoSuchRoom))])
      }
    Move(player, dir) ->
      case dict.get(state.members, player) {
        Ok(member) -> {
          case resolve_direction(state.rooms, member.at, dir) {
            Ok(#(from_room, to_room)) -> {
              let actions = [
                LeaveRoom(player, from_room.subject),
                DescribeRoom(
                  member.session,
                  to_room.name,
                  to_room.description,
                  dict.keys(to_room.exits),
                ),
                EnterRoom(member.session, to_room.subject),
              ]
              let new_state =
                State(
                  ..state,
                  members: dict.insert(
                    state.members,
                    player,
                    Member(member.session, to_room.id),
                  ),
                )
              #(new_state, actions)
            }
            Error(_) -> #(state, [])
          }
        }
        _ -> #(state, [])
      }
    Leave(player) ->
      case dict.get(state.members, player) {
        Ok(member) -> {
          let actions = case dict.get(state.rooms, member.at) {
            Ok(room) -> [LeaveRoom(player, room.subject)]
            Error(_) -> []
          }
          let new_state =
            State(..state, members: dict.delete(state.members, player))
          #(new_state, actions)
        }
        Error(_) -> #(state, [])
      }
    PlayerSays(player, text) ->
      case dict.get(state.members, player) {
        Ok(member) ->
          case dict.get(state.rooms, member.at) {
            Ok(room) -> #(state, [Say(player, room.subject, text)])
            Error(_) -> #(state, [])
          }
        Error(_) -> #(state, [])
      }
    Look(player) ->
      case dict.get(state.members, player) {
        Ok(member) ->
          case dict.get(state.rooms, member.at) {
            Ok(room) -> #(state, [
              DescribeRoom(
                session: member.session,
                room_name: room.name,
                room_description: room.description,
                exits: dict.keys(room.exits),
              ),
            ])
            Error(_) -> #(state, [
              DescribeRoom(
                session: member.session,
                room_name: "a nonexisting room",
                room_description: "An empty void.",
                exits: [],
              ),
            ])
          }
        Error(_) -> #(state, [])
      }
  }
}

fn resolve_direction(
  rooms: Dict(RoomId, RoomInfo),
  at: RoomId,
  dir: Direction,
) -> Result(#(RoomInfo, RoomInfo), Nil) {
  case dict.get(rooms, at) {
    Ok(from_room) ->
      case dict.get(from_room.exits, dir) {
        Ok(to) ->
          case dict.get(rooms, to) {
            Ok(to_room) -> Ok(#(from_room, to_room))
            Error(_) -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

pub fn join(
  world: Subject(Message),
  session: event.Session,
  at: RoomId,
) -> Result(Nil, JoinError) {
  actor.call(world, 1000, Join(session:, at:, reply_to: _))
}

pub fn move(world: Subject(Message), player: PlayerId, dir: Direction) -> Nil {
  actor.send(world, Move(player:, dir:))
}

pub fn say(world: Subject(Message), player: PlayerId, text: String) -> Nil {
  actor.send(world, PlayerSays(player:, text:))
}

pub fn leave(world: Subject(Message), player: PlayerId) -> Nil {
  actor.send(world, Leave(player:))
}

pub fn look(world: Subject(Message), player: PlayerId) -> Nil {
  actor.send(world, Look(player))
}
