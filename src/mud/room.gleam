import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import mud/event
import mud/types.{type PlayerId, type RoomId}

pub type Message {
  PlayerEntered(player: PlayerId, listener: event.Listener)
  PlayerLeft(player: PlayerId)
  Say(speaker: PlayerId, text: String)
}

pub type State {
  State(
    id: RoomId,
    description: String,
    occupants: Dict(PlayerId, event.Listener),
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
        Ok(listener) -> listener.tell(room_event)
        Error(_) -> Nil
      }
    }
  }
}

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    PlayerEntered(player, listener) -> {
      case dict.get(state.occupants, player) {
        Ok(_) -> #(state, [])
        Error(_) -> {
          let occupants = dict.insert(state.occupants, player, listener)
          let tells =
            list.append(broadcast(occupants, event.PlayerEntered(player)), [
              Tell(player, event.RoomDescribed(state.description)),
            ])
          #(State(..state, occupants:), tells)
        }
      }
    }
    PlayerLeft(player) -> {
      case dict.get(state.occupants, player) {
        Ok(_) -> {
          let occupants = dict.delete(state.occupants, player)
          let tells = broadcast(occupants, event.PlayerLeft(player))
          #(State(..state, occupants:), tells)
        }
        Error(_) -> #(state, [])
      }
    }
    Say(speaker, text) -> {
      case dict.get(state.occupants, speaker) {
        Ok(_) -> {
          let tells =
            broadcast(state.occupants, event.PlayerSaid(player: speaker, text:))
          #(state, tells)
        }
        Error(_) -> #(state, [])
      }
    }
  }
}

fn broadcast(
  occupants: Dict(PlayerId, event.Listener),
  room_event: event.RoomEvent,
) -> List(Action) {
  occupants
  |> dict.keys
  |> list.map(Tell(_, room_event))
}

pub fn enter(
  room: Subject(Message),
  player: PlayerId,
  listener: event.Listener,
) -> Nil {
  actor.send(room, PlayerEntered(player:, listener:))
}

pub fn leave(room: Subject(Message), player: PlayerId) -> Nil {
  actor.send(room, PlayerLeft(player:))
}

pub fn say(room: Subject(Message), speaker: PlayerId, text: String) -> Nil {
  actor.send(room, Say(speaker:, text:))
}
