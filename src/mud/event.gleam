import mud/types.{type PlayerId}

pub type RoomEvent {
  YouArrived(room_name: String, room_description: String)
  PlayerArrived(player_name: String)
  PlayerLeft(player_name: String)
  YouSaid(text: String)
  PlayerSaid(player_name: String, text: String)
}

pub type Listener {
  Listener(tell: fn(RoomEvent) -> Nil)
}

pub type Session {
  Session(id: PlayerId, name: String, listener: Listener)
}
