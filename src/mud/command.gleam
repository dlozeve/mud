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
  let assert Ok(re) = regexp.from_string("\\s+")
  let words = line |> string.trim() |> regexp.split(with: re)
  case words {
    [] -> Unknown("")
    [verb, ..rest] ->
      case string.lowercase(verb), rest {
        "help", _ | "?", _ -> Help
        "say", rest -> Say(string.join(rest, " "))
        "go", [] -> MissingDirection
        "go", [dir, ..] ->
          case parse_direction(dir) {
            Ok(dir) -> Go(dir)
            Error(s) -> BadDirection(s)
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

fn parse_direction(s: String) -> Result(Direction, String) {
  case string.lowercase(s) {
    "n" | "north" -> Ok(direction.North)
    "e" | "east" -> Ok(direction.East)
    "s" | "south" -> Ok(direction.South)
    "w" | "west" -> Ok(direction.West)
    _ -> Error(s)
  }
}
