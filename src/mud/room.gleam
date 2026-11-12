import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import mud/event
import mud/id.{type PlayerId, type RoomId}

pub type Message {
  Enter(session: event.Session)
  Leave(player: PlayerId)
  Say(speaker: PlayerId, text: String)
}

pub type State {
  State(
    id: RoomId,
    name: String,
    description: String,
    occupants: Dict(PlayerId, event.Session),
  )
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let #(state, actions) = decide(state, message)
  list.each(actions, run(_, state))
  actor.continue(state)
}

pub type Action {
  Tell(player: PlayerId, room_event: event.RoomEvent)
}

fn run(action: Action, state: State) -> Nil {
  case action {
    Tell(player, room_event) -> {
      case dict.get(state.occupants, player) {
        Ok(session) -> session.listener.tell(room_event)
        Error(_) -> Nil
      }
    }
  }
}

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Enter(session) -> {
      case dict.get(state.occupants, session.id) {
        Ok(_) -> #(state, [])
        Error(_) -> {
          let occupants = dict.insert(state.occupants, session.id, session)
          let tells = [
            Tell(
              session.id,
              event.YouArrived(
                room_name: state.name,
                room_description: state.description,
              ),
            ),
            ..tell_others(
              occupants,
              session.id,
              event.PlayerArrived(session.name),
            )
          ]
          #(State(..state, occupants:), tells)
        }
      }
    }
    Leave(player) -> {
      case dict.get(state.occupants, player) {
        Ok(session) -> {
          let occupants = dict.delete(state.occupants, player)
          let tells = broadcast(occupants, event.PlayerLeft(session.name))
          #(State(..state, occupants:), tells)
        }
        Error(_) -> #(state, [])
      }
    }
    Say(speaker, text) -> {
      case dict.get(state.occupants, speaker) {
        Ok(session) -> {
          let tells = [
            Tell(session.id, event.YouSaid(text:)),
            ..tell_others(
              state.occupants,
              session.id,
              event.PlayerSaid(player_name: session.name, text:),
            )
          ]
          #(state, tells)
        }
        Error(_) -> #(state, [])
      }
    }
  }
}

fn broadcast(
  occupants: Dict(PlayerId, event.Session),
  room_event: event.RoomEvent,
) -> List(Action) {
  occupants
  |> dict.keys
  |> list.map(Tell(_, room_event))
}

fn tell_others(
  occupants: Dict(PlayerId, event.Session),
  except: PlayerId,
  room_event: event.RoomEvent,
) -> List(Action) {
  occupants
  |> dict.delete(except)
  |> dict.keys
  |> list.map(Tell(_, room_event))
}

pub fn enter(room: Subject(Message), session: event.Session) -> Nil {
  actor.send(room, Enter(session))
}

pub fn leave(room: Subject(Message), player: PlayerId) -> Nil {
  actor.send(room, Leave(player:))
}

pub fn say(room: Subject(Message), speaker: PlayerId, text: String) -> Nil {
  actor.send(room, Say(speaker:, text:))
}
