import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import mud/command.{type Command}
import mud/direction.{type Direction}
import mud/event.{type RoomEvent}
import mud/room

// ----- State ------------------------------------------------------------

pub type State {
  State(pid: process.Pid, name: String, room: room.Def)
}

// ----- Action -----------------------------------------------------------

pub type Action {
  Output(String)
  Say(String)
  Move(Direction)
  Look
  WhoIsHere
}

// ----- Logic ------------------------------------------------------------

// for user commands
pub fn decide_command(
  state: State,
  command: Command,
) -> #(State, List(Action)) {
  case command {
    command.Help -> #(state, [Output(help())])
    command.Say(line) -> #(state, [Say(line)])
    command.Go(dir) -> #(state, [Move(dir)])
    command.Look -> #(state, [Look])
    command.WhoIsHere -> #(state, [WhoIsHere])
    command.Quit -> #(state, [])
    command.BadDirection(dir) -> #(state, [Output("Unknown direction: " <> dir)])
    command.MissingDirection -> #(state, [Output("Go where?")])
    command.Unknown(line) -> #(state, [Output("Unknown command: " <> line)])
  }
}

// for messages from other processes
pub fn decide(state: State, room_event: RoomEvent) -> #(State, List(Action)) {
  #(state, [Output(render(room_event))])
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
    event.OccupantArrived(name, event.Player) -> name <> " arrives."
    event.OccupantArrived(name, event.Npc) ->
      string.capitalise(name) <> " has entered the room."
    event.OccupantLeft(name, event.Player) -> name <> " leaves."
    event.OccupantLeft(name, event.Npc) ->
      string.capitalise(name) <> " has left the room."
    event.YouSaid(text) -> "You say: " <> text
    event.OccupantSaid(player_name, text, event.Player) ->
      player_name <> " says: " <> text
    event.OccupantSaid(name, text, event.Npc) ->
      string.capitalise(name) <> " says: " <> text
    event.OccupantList(player_names:, npc_names:) ->
      describe_occupants(player_names, npc_names)
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

fn describe_occupants(
  player_names: List(String),
  npc_names: List(String),
) -> String {
  let player_line = case player_names {
    [] -> ""
    [name] -> name <> " is here."
    names -> {
      let n = list.length(names)
      let #(front, tail) = list.split(names, n - 1)
      string.join(front, ", ") <> " and " <> string.concat(tail) <> " are here."
    }
  }
  let npc_line = case npc_names {
    [] -> ""
    [name] -> "There is " <> name <> " in the room."
    names -> {
      let n = list.length(names)
      let #(front, tail) = list.split(names, n - 1)
      "There are "
      <> string.join(front, ", ")
      <> " and "
      <> string.concat(tail)
      <> " in the room."
    }
  }
  case player_line, npc_line {
    "", "" -> "You are alone here."
    _, "" -> player_line
    "", _ -> npc_line
    _, _ -> player_line <> "\n" <> npc_line
  }
}

fn help() -> String {
  let commands =
    dict.from_list([
      #("help", "Display this help"),
      #("say <message>", "Talk to other players in the room"),
      #("go north/south/east/west (or n/s/e/w)", "Go through a door"),
      #("look", "Look around you"),
      #("who", "Who is here?"),
      #("quit", "Quit the dungeon"),
    ])
  let assert Ok(max_length) =
    dict.keys(commands) |> list.map(string.length) |> list.max(int.compare)
  dict.map_values(commands, fn(cmd, desc) {
    string.pad_end(cmd, to: max_length, with: " ") <> "\t" <> desc
  })
  |> dict.values
  |> list.prepend("Available commands:")
  |> boxed(title: "Help")
}

fn boxed(lines: List(String), title title: String) -> String {
  let max_length = list.map(lines, string.length) |> list.max(int.compare)
  let title_length = string.length(title)
  let header_line = case max_length, title {
    Ok(n), "" -> "┌" <> string.repeat("─", n + 2) <> "┐"
    Ok(n), title ->
      "┌"
      <> string.repeat("─", { n - title_length } / 2)
      <> " "
      <> title
      <> " "
      <> string.repeat("─", { n - title_length } / 2 + { n - title_length } % 2)
      <> "┐"
    Error(_), _ -> ""
  }
  case max_length {
    Ok(n) -> {
      let padded_lines =
        list.map(lines, string.pad_end(_, to: n, with: " "))
        |> string.join(" │\n│ ")
      let footer_line = "└" <> string.repeat("─", n + 2) <> "┘"
      header_line <> "\n" <> "│ " <> padded_lines <> " │\n" <> footer_line
    }
    Error(_) -> ""
  }
}
