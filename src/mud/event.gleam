import gleam/erlang/process
import mud/direction.{type Direction}
import mud/id.{type PlayerId, type RoomId}

pub type RoomEvent {
  YouAreIn(room_name: String, room_description: String, exits: List(Direction))
  PlayerArrived(player_name: String)
  PlayerLeft(player_name: String)
  YouSaid(text: String)
  PlayerSaid(player_name: String, text: String)
}

pub type Listener {
  Listener(tell: fn(RoomId, RoomEvent) -> Nil)
}

pub type Session {
  Session(id: PlayerId, name: String, pid: process.Pid, listener: Listener)
}
