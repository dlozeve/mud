pub type Direction {
  North
  East
  South
  West
}

pub fn render(dir: Direction) -> String {
  case dir {
    North -> "North"
    East -> "East"
    South -> "South"
    West -> "West"
  }
}

pub fn all() -> List(Direction) {
  [North, East, South, West]
}
