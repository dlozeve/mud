import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
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
  RoomInfo(subject: Subject(room.Message), name: String, description: String)
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
  case message {
    Join(session, at) -> {
      case dict.get(state.members, session.id) {
        Ok(_) -> actor.continue(state)
        Error(_) ->
          case dict.get(state.rooms, at) {
            Ok(room) -> {
              session.listener.tell(event.YouArrived(
                room_name: room.name,
                room_description: room.description,
              ))
              room.enter(room.subject, session)
              actor.continue(
                State(
                  ..state,
                  members: dict.insert(
                    state.members,
                    session.id,
                    Member(session, at),
                  ),
                ),
              )
            }
            Error(_) -> actor.continue(state)
          }
      }
    }
    Move(player, to) -> {
      case dict.get(state.members, player), dict.get(state.rooms, to) {
        Ok(member), Ok(to_room) if member.at != to -> {
          case dict.get(state.rooms, member.at) {
            Ok(from_room) -> {
              room.leave(from_room.subject, player)
              member.session.listener.tell(event.YouArrived(
                room_name: to_room.name,
                room_description: to_room.description,
              ))
              room.enter(to_room.subject, member.session)
              actor.continue(
                State(
                  ..state,
                  members: dict.insert(
                    state.members,
                    player,
                    Member(member.session, to),
                  ),
                ),
              )
            }
            Error(_) -> actor.continue(state)
          }
        }
        _, _ -> actor.continue(state)
      }
    }
    Leave(player) -> {
      case dict.get(state.members, player) {
        Ok(member) ->
          case dict.get(state.rooms, member.at) {
            Ok(room) -> {
              room.leave(room.subject, player)
              actor.continue(
                State(..state, members: dict.delete(state.members, player)),
              )
            }
            Error(_) -> actor.continue(state)
          }
        Error(_) -> actor.continue(state)
      }
    }
    PlayerSays(player, text) -> {
      case dict.get(state.members, player) {
        Ok(member) ->
          case dict.get(state.rooms, member.at) {
            Ok(room) -> {
              room.say(room.subject, player, text)
              actor.continue(state)
            }
            Error(_) -> actor.continue(state)
          }
        Error(_) -> actor.continue(state)
      }
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
