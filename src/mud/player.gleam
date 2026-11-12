import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/otp/actor
import mud/event.{type RoomEvent}
import mud/id.{type PlayerId, type RoomId}
import mud/world

pub type Message {
  Event(RoomEvent)
  Input(line: String)
  Move(to: RoomId)
  Disconnect
}

pub type State {
  State(id: PlayerId, name: String, world: Subject(world.Message))
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Event(room_event) -> {
      io.println("[" <> state.name <> "] " <> render(room_event))
      actor.continue(state)
    }
    Input(line) -> {
      world.say(state.world, state.id, line)
      actor.continue(state)
    }
    Move(room) -> {
      world.move(state.world, state.id, room)
      actor.continue(state)
    }
    Disconnect -> {
      world.leave(state.world, state.id)
      actor.stop()
    }
  }
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

pub fn move(player: Subject(Message), to: RoomId) -> Nil {
  actor.send(player, Move(to:))
}

pub fn input(player: Subject(Message), line: String) -> Nil {
  actor.send(player, Input(line:))
}

pub fn disconnect(player: Subject(Message)) -> Nil {
  actor.send(player, Disconnect)
}
