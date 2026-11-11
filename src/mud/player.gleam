import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/otp/actor
import mud/event.{type RoomEvent}
import mud/types.{type PlayerId}

pub type Message {
  Event(RoomEvent)
}

pub type State {
  State(id: PlayerId)
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Event(event.PlayerSaid(player, text)) -> {
      io.println(
        "Player "
        <> state.id
        <> " received message from "
        <> player
        <> ": \""
        <> text
        <> "\"",
      )
    }
    Event(event.PlayerEntered(_player)) -> Nil
    Event(event.PlayerLeft(_player)) -> Nil
    Event(event.RoomDescribed(text)) -> {
      io.println(
        "Player "
        <> state.id
        <> " received the room description: \""
        <> text
        <> "\"",
      )
    }
  }
  actor.continue(state)
}

pub fn to_listener(player: Subject(Message)) -> event.Listener {
  event.Listener(fn(room_event) { process.send(player, Event(room_event)) })
}
