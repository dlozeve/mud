import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/io
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
      io.println("Player " <> player <> " entered " <> state.id)
      let new_occupants = dict.insert(state.occupants, player, listener)
      listener.tell(event.RoomDescribed(
        "You entered room " <> state.id <> ": \"" <> state.description <> "\"",
      ))
      actor.continue(State(..state, occupants: new_occupants))
    }
    PlayerLeft(player) -> {
      io.println("Player " <> player <> " left room " <> state.id)
      let new_occupants = dict.delete(state.occupants, player)
      actor.continue(State(..state, occupants: new_occupants))
    }
    Say(sender_id, text) -> {
      io.println("Player " <> sender_id <> " said: \"" <> text <> "\"")
      dict.each(dict.delete(state.occupants, sender_id), fn(_id, listener) {
        listener.tell(event.PlayerSaid(player: sender_id, text:))
      })
      actor.continue(state)
    }
  }
}

pub fn enter(
  room: Subject(Message),
  player: PlayerId,
  listener: event.Listener,
) {
  actor.send(room, PlayerEntered(player:, listener:))
}
