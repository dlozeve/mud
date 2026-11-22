import mud/direction.{type Direction}

pub type RoomEvent {
  YouAreIn(room_name: String, room_description: String, exits: List(Direction))
  OccupantArrived(name: String, kind: OccupantKind)
  OccupantLeft(name: String, kind: OccupantKind)
  YouSaid(text: String)
  OccupantSaid(name: String, text: String, kind: OccupantKind)
  OccupantList(player_names: List(String), npc_names: List(String))
}

pub type OccupantKind {
  Player
  Npc
}
