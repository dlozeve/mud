import gleam/erlang/process
import mud/direction.{type Direction}

pub type RoomEvent {
  YouAreIn(room_name: String, room_description: String, exits: List(Direction))
  OccupantArrived(name: String, kind: OccupantKind)
  OccupantLeft(name: String, kind: OccupantKind)
  OccupantDied(name: String, kind: OccupantKind)
  YouSaid(text: String)
  OccupantSaid(name: String, text: String, kind: OccupantKind)
  OccupantList(player_names: List(String), npc_names: List(String))
  // Combat events. The room is the switchboard: it tells the attacker the
  // outcome, tells the NPC it was attacked, and tells a player when an NPC
  // lands a hit.
  AttackFailed(target_name: String)
  YouHitNpc(name: String, damage: Int)
  YouMissedNpc(name: String)
  NpcAttacked(attacker_name: String, attacker_pid: process.Pid, damage: Int)
  NpcHitYou(name: String, damage: Int)
  NpcTargetGone
}

pub type OccupantKind {
  Player
  Npc
}
