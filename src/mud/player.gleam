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
    Event(room_event) ->
      io.println("[" <> state.id <> "] " <> render(room_event, state.id))
  }
  actor.continue(state)
}

pub fn render(room_event: event.RoomEvent, viewer: PlayerId) -> String {
  case room_event {
    event.PlayerSaid(player, text) if viewer == player -> "You say: " <> text
    event.PlayerSaid(player, text) -> player <> " says: " <> text
    event.PlayerEntered(player) if viewer == player -> "You enter the room."
    event.PlayerEntered(player) -> player <> " enters the room."
    event.PlayerLeft(player) if viewer == player -> "You leave the room."
    event.PlayerLeft(player) -> player <> " leaves the room."
    event.RoomDescribed(text) -> text
  }
}

pub fn to_listener(player: Subject(Message)) -> event.Listener {
  event.Listener(fn(room_event) { process.send(player, Event(room_event)) })
}
