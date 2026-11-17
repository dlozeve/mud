import mud/direction.{type Direction}

pub type RoomEvent {
  YouAreIn(room_name: String, room_description: String, exits: List(Direction))
  PlayerArrived(player_name: String)
  PlayerLeft(player_name: String)
  YouSaid(text: String)
  PlayerSaid(player_name: String, text: String)
}
