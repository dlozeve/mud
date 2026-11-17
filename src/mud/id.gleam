import youid/uuid

pub opaque type RoomId {
  RoomId(uuid.Uuid)
}

pub fn new_room_id() -> RoomId {
  RoomId(uuid.v7())
}
