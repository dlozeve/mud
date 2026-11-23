import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import mud/combat
import mud/direction.{type Direction}
import mud/event
import mud/log
import woof

// ----- Identity and handles ---------------------------------------------

pub opaque type Id {
  Id(String)
}

pub fn new_id(name: String) -> Id {
  Id(name)
}

pub fn id_to_string(id: Id) -> String {
  let Id(s) = id
  s
}

// A room's view of one player or NPC: the name for display, the pid that identifies
// the connection (it keys the occupant map and is monitored for eviction), and
// the listener that delivers room events to them.
pub type Occupant {
  Occupant(
    name: String,
    pid: process.Pid,
    kind: event.OccupantKind,
    listener: Listener,
  )
}

pub type Listener {
  Listener(tell: fn(Id, event.RoomEvent) -> Nil)
}

pub fn occupant(
  name: String,
  pid: process.Pid,
  kind: event.OccupantKind,
  tell: fn(Id, event.RoomEvent) -> Nil,
) -> Occupant {
  Occupant(name: name, pid: pid, listener: Listener(tell), kind:)
}

// ----- State ------------------------------------------------------------

// Occupants are keyed by their connection pid.
pub type State {
  State(def: Def, occupants: Dict(process.Pid, Occupant))
}

pub type Def {
  Def(
    process_name: process.Name(Message),
    id: Id,
    name: String,
    description: String,
    exits: Dict(Direction, Id),
  )
}

// ----- Message ----------------------------------------------------------

pub type Message {
  Enter(occupant: Occupant)
  Leave(pid: process.Pid)
  Look(pid: process.Pid)
  WhoIsHere(pid: process.Pid)
  Say(speaker: process.Pid, text: String)
  Attack(attacker: process.Pid, target_name: String, hit: Bool)
  NpcAttack(
    npc_pid: process.Pid,
    target_pid: process.Pid,
    npc_name: String,
    damage: Int,
  )
  Died(pid: process.Pid)
  Down(pid: Option(process.Pid))
}

// ----- Action -----------------------------------------------------------

pub type Action {
  Tell(pid: process.Pid, room_event: event.RoomEvent)
  Monitor(pid: process.Pid)
}

// ----- Logic ------------------------------------------------------------

pub fn decide(
  state: State,
  message: Message,
) -> #(State, List(Action), List(log.Line)) {
  case message {
    Enter(occupant) -> {
      case dict.get(state.occupants, occupant.pid) {
        Ok(_) -> {
          let logs = [
            log.Line(woof.Warning, "occupant already in room", [
              log.occupant_name(occupant.name),
              log.occupant_pid(occupant.pid),
              log.occupant_kind(occupant.kind),
            ]),
          ]
          #(state, [], logs)
        }
        Error(_) -> {
          let occupants = dict.insert(state.occupants, occupant.pid, occupant)
          let actions =
            list.append(
              [Monitor(occupant.pid), ..you_are_in_actions(state, occupant)],
              tell_others(
                occupants,
                occupant.pid,
                event.OccupantArrived(occupant.name, occupant.kind),
              ),
            )
          let logs = [
            log.Line(woof.Debug, "occupant entered room", [
              log.occupant_name(occupant.name),
              log.occupant_pid(occupant.pid),
              log.occupant_kind(occupant.kind),
            ]),
          ]
          #(State(..state, occupants:), actions, logs)
        }
      }
    }
    Leave(pid) -> {
      case dict.get(state.occupants, pid) {
        Ok(occupant) -> {
          let occupants = dict.delete(state.occupants, pid)
          let tells =
            broadcast(
              occupants,
              event.OccupantLeft(occupant.name, occupant.kind),
            )
          let logs = [
            log.Line(woof.Debug, "occupant left room", [
              log.occupant_name(occupant.name),
              log.occupant_pid(occupant.pid),
              log.occupant_kind(occupant.kind),
            ]),
          ]
          #(State(..state, occupants:), tells, logs)
        }
        Error(_) -> {
          // Not a warning: it's expected when a connection is terminated,
          // as both a Leave event is triggered and the monitor is down
          let logs = [
            log.Line(woof.Debug, "occupant not present in room on leave", [
              log.occupant_pid(pid),
            ]),
          ]
          #(state, [], logs)
        }
      }
    }
    Look(pid) ->
      case dict.get(state.occupants, pid) {
        Ok(occupant) -> {
          let logs = [
            log.Line(woof.Debug, "player looked", [
              log.occupant_name(occupant.name),
              log.occupant_pid(occupant.pid),
            ]),
          ]
          #(state, [Tell(pid, you_are_in(state))], logs)
        }
        Error(_) -> {
          let logs = [
            log.Line(woof.Debug, "player not present in room on look", [
              log.occupant_pid(pid),
            ]),
          ]
          #(state, [], logs)
        }
      }
    WhoIsHere(pid) ->
      case dict.get(state.occupants, pid) {
        Ok(occupant) -> {
          let actions = [
            Tell(
              pid,
              event.OccupantList(
                player_names: dict.delete(state.occupants, pid)
                  |> dict.filter(fn(_, occupant) {
                    case occupant.kind {
                      event.Player -> True
                      event.Npc -> False
                    }
                  })
                  |> dict.map_values(fn(_, occupant) { occupant.name })
                  |> dict.values,
                npc_names: dict.delete(state.occupants, pid)
                  |> dict.filter(fn(_, occupant) {
                    case occupant.kind {
                      event.Npc -> True
                      event.Player -> False
                    }
                  })
                  |> dict.map_values(fn(_, occupant) { occupant.name })
                  |> dict.values,
              ),
            ),
          ]
          let logs = [
            log.Line(woof.Debug, "player asked who is here", [
              log.occupant_name(occupant.name),
              log.occupant_pid(occupant.pid),
            ]),
          ]
          #(state, actions, logs)
        }
        Error(_) -> {
          let logs = [
            log.Line(woof.Debug, "player not present in room on who is here", [
              log.occupant_pid(pid),
            ]),
          ]
          #(state, [], logs)
        }
      }
    Say(speaker, text) -> {
      case dict.get(state.occupants, speaker) {
        Ok(occupant) -> {
          let tells =
            list.append(
              you_said_actions(occupant, text),
              tell_others(
                state.occupants,
                speaker,
                event.OccupantSaid(
                  name: occupant.name,
                  text:,
                  kind: occupant.kind,
                ),
              ),
            )
          let logs = [
            log.Line(woof.Debug, "occupant spoke", [
              log.occupant_name(occupant.name),
              log.occupant_pid(occupant.pid),
              log.occupant_kind(occupant.kind),
              woof.str("text", text),
            ]),
          ]
          #(state, tells, logs)
        }
        Error(_) -> {
          let logs = [
            log.Line(woof.Debug, "occupant not present in room on say", [
              log.occupant_pid(speaker),
            ]),
          ]
          #(state, [], logs)
        }
      }
    }
    Attack(attacker, target_name, hit) -> {
      case dict.get(state.occupants, attacker) {
        Error(_) -> {
          let logs = [
            log.Line(woof.Debug, "attacker not present in room on attack", [
              log.occupant_pid(attacker),
            ]),
          ]
          #(state, [], logs)
        }
        Ok(attacker_occupant) ->
          case find_npc(state.occupants, target_name) {
            Error(_) -> {
              let logs = [
                log.Line(woof.Debug, "attack target not found", [
                  log.occupant_name(attacker_occupant.name),
                  woof.str("target_name", target_name),
                ]),
              ]
              #(state, [Tell(attacker, event.AttackFailed(target_name))], logs)
            }
            Ok(target) -> {
              let damage = case hit {
                True -> combat.player_damage
                False -> 0
              }
              let outcome = case hit {
                True -> event.YouHitNpc(target.name, damage)
                False -> event.YouMissedNpc(target.name)
              }
              let actions = [
                Tell(attacker, outcome),
                Tell(
                  target.pid,
                  event.NpcAttacked(
                    attacker_name: attacker_occupant.name,
                    attacker_pid: attacker_occupant.pid,
                    damage:,
                  ),
                ),
              ]
              let logs = [
                log.Line(woof.Debug, "player attacked npc", [
                  log.occupant_name(attacker_occupant.name),
                  log.occupant_name(target.name),
                  woof.bool("hit", hit),
                ]),
              ]
              #(state, actions, logs)
            }
          }
      }
    }
    NpcAttack(npc_pid, target_pid, npc_name, damage) ->
      case dict.get(state.occupants, target_pid) {
        Ok(target) ->
          case target.kind {
            event.Player -> {
              let logs = [
                log.Line(woof.Debug, "npc attacked player", [
                  log.occupant_name(npc_name),
                  log.occupant_name(target.name),
                  woof.int("damage", damage),
                ]),
              ]
              #(
                state,
                [Tell(target_pid, event.NpcHitYou(npc_name, damage))],
                logs,
              )
            }
            event.Npc -> #(state, [], [])
          }
        Error(_) -> {
          // The target left the room (or died): tell the NPC to stop chasing it.
          let logs = [
            log.Line(woof.Debug, "npc attack target not present in room", [
              log.occupant_name(npc_name),
              log.occupant_pid(target_pid),
            ]),
          ]
          #(state, [Tell(npc_pid, event.NpcTargetGone)], logs)
        }
      }
    Died(pid) -> {
      case dict.get(state.occupants, pid) {
        Ok(occupant) -> {
          let occupants = dict.delete(state.occupants, pid)
          let tells =
            broadcast(
              occupants,
              event.OccupantDied(occupant.name, occupant.kind),
            )
          let logs = [
            log.Line(woof.Debug, "occupant died", [
              log.occupant_name(occupant.name),
              log.occupant_pid(occupant.pid),
              log.occupant_kind(occupant.kind),
            ]),
          ]
          #(State(..state, occupants:), tells, logs)
        }
        Error(_) -> {
          let logs = [
            log.Line(woof.Debug, "occupant not present in room on death", [
              log.occupant_pid(pid),
            ]),
          ]
          #(state, [], logs)
        }
      }
    }
    Down(Some(pid)) -> {
      let #(state, actions, logs) = decide(state, Leave(pid))
      let down =
        log.Line(woof.Debug, "occupant process down", [log.occupant_pid(pid)])
      #(state, actions, [down, ..logs])
    }
    Down(None) -> #(state, [], [])
  }
}

fn find_npc(
  occupants: Dict(process.Pid, Occupant),
  target_name: String,
) -> Result(Occupant, Nil) {
  occupants
  |> dict.values
  |> list.find(fn(occupant) {
    case occupant.kind {
      event.Npc -> matches_name(occupant.name, target_name)
      event.Player -> False
    }
  })
}

// Players should not have to type the article: "attack goblin" and
// "attack a goblin" both find the same NPC.
fn matches_name(occupant_name: String, target_name: String) -> Bool {
  let name = string.lowercase(occupant_name)
  let target = string.lowercase(target_name)
  name == target
  || name == "a " <> target
  || name == "an " <> target
  || name == "the " <> target
}

fn you_are_in(state: State) -> event.RoomEvent {
  event.YouAreIn(
    room_name: state.def.name,
    room_description: state.def.description,
    exits: list.filter(direction.all(), fn(each_direction) {
      dict.has_key(state.def.exits, each_direction)
    }),
  )
}

// Second-person events are addressed to a player: an NPC has no "you" to
// address, and ignores them, so they are not sent to one.
fn you_are_in_actions(state: State, occupant: Occupant) -> List(Action) {
  case occupant.kind {
    event.Player -> [Tell(occupant.pid, you_are_in(state))]
    event.Npc -> []
  }
}

fn you_said_actions(occupant: Occupant, text: String) -> List(Action) {
  case occupant.kind {
    event.Player -> [Tell(occupant.pid, event.YouSaid(text:))]
    event.Npc -> []
  }
}

fn broadcast(
  occupants: Dict(process.Pid, Occupant),
  room_event: event.RoomEvent,
) -> List(Action) {
  occupants
  |> dict.keys
  |> list.map(Tell(_, room_event))
}

fn tell_others(
  occupants: Dict(process.Pid, Occupant),
  except: process.Pid,
  room_event: event.RoomEvent,
) -> List(Action) {
  occupants
  |> dict.delete(except)
  |> dict.keys
  |> list.map(Tell(_, room_event))
}

// ----- Execution --------------------------------------------------------

fn run(action: Action, state: State) -> Nil {
  case action {
    Tell(pid, room_event) -> {
      case dict.get(state.occupants, pid) {
        Ok(session) -> session.listener.tell(state.def.id, room_event)
        Error(_) -> Nil
      }
    }
    Monitor(pid) -> {
      let _ = process.monitor(pid)
      Nil
    }
  }
}

pub fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let logger =
    log.room_logger(id_to_string(state.def.id), dict.size(state.occupants))
  let #(state, actions, logs) = decide(state, message)
  list.each(logs, log.emit(logger, _))
  list.each(actions, run(_, state))
  actor.continue(state)
}

// ------ Public helpers --------------------------------------------------

fn checked_named_subject(
  name: process.Name(a),
) -> Result(process.Subject(a), Nil) {
  case process.named(name) {
    Ok(_pid) -> Ok(process.named_subject(name))
    Error(_) -> Error(Nil)
  }
}

pub fn enter(room_name: process.Name(Message), occupant: Occupant) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Enter(occupant))
    Error(_) -> Nil
  }
}

pub fn leave(room_name: process.Name(Message), pid: process.Pid) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Leave(pid:))
    Error(_) -> Nil
  }
}

pub fn look(room_name: process.Name(Message), pid: process.Pid) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Look(pid:))
    Error(_) -> Nil
  }
}

pub fn who_is_here(room_name: process.Name(Message), pid: process.Pid) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, WhoIsHere(pid:))
    Error(_) -> Nil
  }
}

pub fn say(
  room_name: process.Name(Message),
  speaker: process.Pid,
  text: String,
) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Say(speaker:, text:))
    Error(_) -> Nil
  }
}

pub fn attack(
  room_name: process.Name(Message),
  attacker: process.Pid,
  target_name: String,
  hit: Bool,
) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Attack(attacker:, target_name:, hit:))
    Error(_) -> Nil
  }
}

pub fn npc_attack(
  room_name: process.Name(Message),
  npc_pid: process.Pid,
  target_pid: process.Pid,
  npc_name: String,
  damage: Int,
) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) ->
      actor.send(subject, NpcAttack(npc_pid:, target_pid:, npc_name:, damage:))
    Error(_) -> Nil
  }
}

pub fn died(room_name: process.Name(Message), pid: process.Pid) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Died(pid:))
    Error(_) -> Nil
  }
}
