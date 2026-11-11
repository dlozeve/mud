pub opaque type PlayerId {
  PlayerId(String)
}

pub fn new_player_id(id: String) -> PlayerId {
  PlayerId(id)
}

pub opaque type RoomId {
  RoomId(String)
}

pub fn new_room_id(id: String) -> RoomId {
  RoomId(id)
}
