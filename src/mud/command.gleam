import gleam/regexp
import gleam/string
import mud/direction.{type Direction}

pub type Command {
  Help
  Say(String)
  Go(Direction)
  Look
  WhoIsHere
  Attack(String)
  Quit
  BadDirection(String)
  MissingDirection
  MissingTarget
  Unknown(String)
}

pub fn parse(line: String) -> Command {
  let assert Ok(split_pattern) = regexp.from_string("\\s+")
  let words = line |> string.trim() |> regexp.split(with: split_pattern)
  case words {
    [] -> Unknown("")
    [verb, ..rest] ->
      case string.lowercase(verb), rest {
        "help", _ | "?", _ -> Help
        "say", rest -> Say(string.join(rest, " "))
        "go", [] -> MissingDirection
        "go", [direction_text, ..] ->
          case parse_direction(direction_text) {
            Ok(parsed_direction) -> Go(parsed_direction)
            Error(text) -> BadDirection(text)
          }
        "look", _ -> Look
        "who", _ -> WhoIsHere
        "attack", [] -> MissingTarget
        "attack", rest -> Attack(string.join(rest, " "))
        "q", _ | "quit", _ -> Quit
        _, _ -> Unknown(line)
      }
  }
}

fn parse_direction(input: String) -> Result(Direction, String) {
  case string.lowercase(input) {
    "n" | "north" -> Ok(direction.North)
    "e" | "east" -> Ok(direction.East)
    "s" | "south" -> Ok(direction.South)
    "w" | "west" -> Ok(direction.West)
    "u" | "up" -> Ok(direction.Up)
    "d" | "down" -> Ok(direction.Down)
    _ -> Error(input)
  }
}
