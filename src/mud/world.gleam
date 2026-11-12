import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import mud/event
import mud/id.{type PlayerId, type RoomId}
import mud/room

pub type Message {
  Join(session: event.Session, at: RoomId)
  Move(player: PlayerId, to: RoomId)
  Leave(player: PlayerId)
  PlayerSays(player: PlayerId, text: String)
}

pub type RoomInfo {
  RoomInfo(
    subject: Subject(room.Message),
    id: RoomId,
    name: String,
    description: String,
  )
}

pub type Member {
  Member(session: event.Session, at: RoomId)
}

pub type State {
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
  TellYouArrived(
    session: event.Session,
    room_name: String,
    room_description: String,
  )
  EnterRoom(session: event.Session, room: Subject(room.Message))
  LeaveRoom(player: PlayerId, room: Subject(room.Message))
  Say(player: PlayerId, room: Subject(room.Message), text: String)
}

fn run(action: Action) -> Nil {
  case action {
    TellYouArrived(session, room_name, room_description) ->
      session.listener.tell(event.YouArrived(room_name:, room_description:))
    EnterRoom(session, room_subject) -> room.enter(room_subject, session)
    LeaveRoom(player, room_subject) -> room.leave(room_subject, player)
    Say(player_id, room_subject, text) ->
      room.say(room_subject, player_id, text)
  }
}

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Join(session, at) ->
      case dict.get(state.members, session.id), dict.get(state.rooms, at) {
        Ok(_), _ -> #(state, [])
        Error(_), Ok(room) -> {
          let actions = [
            TellYouArrived(session, room.name, room.description),
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
        Error(_), Error(_) -> #(state, [])
      }
    Move(player, to) ->
      case dict.get(state.members, player), dict.get(state.rooms, to) {
        Ok(member), Ok(to_room) if member.at != to -> {
          let actions = case dict.get(state.rooms, member.at) {
            Ok(from_room) -> [
              LeaveRoom(player, from_room.subject),
              TellYouArrived(member.session, to_room.name, to_room.description),
              EnterRoom(member.session, to_room.subject),
            ]
            // If we can't find the origin, we don't leave, we just enter the new room
            Error(_) -> [
              TellYouArrived(member.session, to_room.name, to_room.description),
              EnterRoom(member.session, to_room.subject),
            ]
          }
          let new_state =
            State(
              ..state,
              members: dict.insert(
                state.members,
                player,
                Member(member.session, to),
              ),
            )
          #(new_state, actions)
        }
        _, _ -> #(state, [])
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
  }
}

pub fn join(
  world: Subject(Message),
  session: event.Session,
  at: RoomId,
) -> Nil {
  actor.send(world, Join(session:, at:))
}

pub fn move(world: Subject(Message), player: PlayerId, to: RoomId) -> Nil {
  actor.send(world, Move(player:, to:))
}

pub fn say(world: Subject(Message), player: PlayerId, text: String) -> Nil {
  actor.send(world, PlayerSays(player:, text:))
}

pub fn leave(world: Subject(Message), player: PlayerId) -> Nil {
  actor.send(world, Leave(player:))
}
