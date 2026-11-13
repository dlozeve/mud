import gleam/string
import mud/direction.{type Direction}

pub type Command {
  Say(String)
  Go(Direction)
  Look
  Quit
  Unknown(String)
}

pub fn parse(line: String) -> Command {
  let words = line |> string.trim() |> string.split(" ")
  case words {
    [] -> Unknown("")
    [verb, ..rest] ->
      case string.lowercase(verb), rest {
        "say", rest -> Say(string.join(rest, " "))
        "go", [dir, ..] ->
          case parse_direction(dir) {
            Ok(dir) -> Go(dir)
            Error(s) -> Unknown("Unknown direction: " <> s)
          }
        "go", _ -> Unknown(line)
        "look", _ -> Look
        "quit", _ -> Quit
        _, _ -> Unknown(line)
      }
  }
}

fn parse_direction(s: String) -> Result(Direction, String) {
  case string.lowercase(s) {
    "north" -> Ok(direction.North)
    "east" -> Ok(direction.East)
    "south" -> Ok(direction.South)
    "west" -> Ok(direction.West)
    _ -> Error(s)
  }
}
