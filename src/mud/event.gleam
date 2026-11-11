import mud/types.{type PlayerId}

pub type RoomEvent {
  PlayerEntered(player: PlayerId)
  PlayerLeft(player: PlayerId)
  PlayerSaid(player: PlayerId, text: String)
  RoomDescribed(text: String)
}

pub type Listener {
  Listener(tell: fn(RoomEvent) -> Nil)
}
