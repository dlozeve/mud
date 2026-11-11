import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
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
  case message {
    PlayerEntered(player, listener) -> {
      let new_occupants = dict.insert(state.occupants, player, listener)
      broadcast(new_occupants, event.PlayerEntered(player))
      listener.tell(event.RoomDescribed(state.description))
      actor.continue(State(..state, occupants: new_occupants))
    }
    PlayerLeft(player) -> {
      broadcast(state.occupants, event.PlayerLeft(player))
      let new_occupants = dict.delete(state.occupants, player)
      actor.continue(State(..state, occupants: new_occupants))
    }
    Say(speaker, text) -> {
      broadcast(state.occupants, event.PlayerSaid(player: speaker, text:))
      actor.continue(state)
    }
  }
}

fn broadcast(
  occupants: Dict(PlayerId, event.Listener),
  room_event: event.RoomEvent,
) -> Nil {
  dict.each(occupants, fn(_id, listener) { listener.tell(room_event) })
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
