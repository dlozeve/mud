import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/otp/actor
import mud/event.{type RoomEvent}
import mud/id.{type PlayerId}

pub type Message {
  Event(RoomEvent)
}

pub type State {
  State(id: PlayerId, name: String)
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Event(room_event) ->
      io.println("[" <> state.name <> "] " <> render(room_event))
  }
  actor.continue(state)
}

pub fn render(room_event: event.RoomEvent) -> String {
  case room_event {
    event.YouArrived(room_name, room_description) ->
      "You enter " <> room_name <> ".\n" <> room_description
    event.PlayerArrived(player_name) -> player_name <> " arrives."
    event.PlayerLeft(player_name) -> player_name <> " leaves."
    event.YouSaid(text) -> "You say: " <> text
    event.PlayerSaid(player_name, text) -> player_name <> " says: " <> text
  }
}

fn to_listener(player: Subject(Message)) -> event.Listener {
  event.Listener(fn(room_event) { process.send(player, Event(room_event)) })
}

pub fn to_session(player: Subject(Message), state: State) -> event.Session {
  event.Session(state.id, state.name, to_listener(player))
}
