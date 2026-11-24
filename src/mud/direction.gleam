pub type Direction {
  North
  East
  South
  West
  Up
  Down
}

pub fn render(direction: Direction) -> String {
  case direction {
    North -> "North"
    East -> "East"
    South -> "South"
    West -> "West"
    Up -> "up"
    Down -> "down"
  }
}

pub fn all() -> List(Direction) {
  [North, East, South, West, Up, Down]
}
