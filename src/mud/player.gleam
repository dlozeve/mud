import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string
import mud/command.{type Command}
import mud/direction.{type Direction}
import mud/event.{type RoomEvent}
import mud/id.{type PlayerId}
import mud/world

// ----- State ------------------------------------------------------------

pub type State {
  State(
    id: PlayerId,
    name: String,
    world: Subject(world.Message),
    room: world.RoomInfo,
  )
}

// ----- Message ----------------------------------------------------------

pub type Message {
  Event(RoomEvent)
}

// ----- Action -----------------------------------------------------------

pub type Action {
  Output(String)
  Say(String)
  Move(Direction)
  Look
  Leave
  Unknown(String)
}

// ----- Logic ------------------------------------------------------------

// for user commands
pub fn decide_command(
  state: State,
  command: Command,
) -> #(State, List(Action)) {
  case command {
    command.Say(line) -> #(state, [Say(line)])
    command.Go(dir) -> #(state, [Move(dir)])
    command.Look -> #(state, [Look])
    command.Quit -> #(state, [Leave])
    command.Unknown(line) -> #(state, [Unknown(line)])
  }
}

// for messages from other processes
pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Event(room_event) -> #(state, [Output(render(room_event))])
  }
}

pub fn render(room_event: event.RoomEvent) -> String {
  case room_event {
    event.YouAreIn(room_name, room_description, exits) ->
      "You are in "
      <> room_name
      <> ".\n"
      <> room_description
      <> "\n"
      <> describe_exits(exits)
    event.PlayerArrived(player_name) -> player_name <> " arrives."
    event.PlayerLeft(player_name) -> player_name <> " leaves."
    event.YouSaid(text) -> "You say: " <> text
    event.PlayerSaid(player_name, text) -> player_name <> " says: " <> text
  }
}

fn describe_exits(exits: List(Direction)) -> String {
  case list.map(exits, direction.render) {
    [] -> "There is no exit."
    [a] -> "There is a single door, " <> a <> "."
    [a, b] -> "There are two doors: " <> a <> " and " <> b <> "."
    words -> {
      let n = list.length(words)
      let #(front, tail) = list.split(words, n - 1)
      "There are "
      <> int.to_string(n)
      <> " doors: "
      <> string.join(front, ", ")
      <> " and "
      <> string.concat(tail)
      <> "."
    }
  }
}

// ------ Public helpers --------------------------------------------------

fn to_listener(player: Subject(Message)) -> event.Listener {
  event.Listener(fn(room_event) { process.send(player, Event(room_event)) })
}

pub fn to_session(player: Subject(Message), state: State) -> event.Session {
  event.Session(state.id, state.name, to_listener(player))
}
