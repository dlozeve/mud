import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import mud/direction.{type Direction}
import mud/event
import youid/uuid

// ----- Identity and handles ---------------------------------------------

pub opaque type Id {
  Id(uuid.Uuid)
}

pub fn new_id() -> Id {
  Id(uuid.v7())
}

// A room's view of one player: the name for display, the pid that identifies
// the connection (it keys the occupant map and is monitored for eviction), and
// the listener that delivers room events to them.
pub type Occupant {
  Occupant(name: String, pid: process.Pid, listener: Listener)
}

pub type Listener {
  Listener(tell: fn(Id, event.RoomEvent) -> Nil)
}

pub fn occupant(
  name: String,
  pid: process.Pid,
  tell: fn(Id, event.RoomEvent) -> Nil,
) -> Occupant {
  Occupant(name: name, pid: pid, listener: Listener(tell))
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
  Say(speaker: process.Pid, text: String)
  Down(pid: Option(process.Pid))
}

// ----- Action -----------------------------------------------------------

pub type Action {
  Tell(pid: process.Pid, room_event: event.RoomEvent)
  Monitor(pid: process.Pid)
}

// ----- Logic ------------------------------------------------------------

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Enter(occupant) -> {
      case dict.get(state.occupants, occupant.pid) {
        Ok(_) -> #(state, [])
        Error(_) -> {
          let occupants = dict.insert(state.occupants, occupant.pid, occupant)
          let actions = [
            Monitor(occupant.pid),
            Tell(occupant.pid, you_are_in(state)),
            ..tell_others(
              occupants,
              occupant.pid,
              event.PlayerArrived(occupant.name),
            )
          ]
          #(State(..state, occupants:), actions)
        }
      }
    }
    Leave(pid) -> {
      case dict.get(state.occupants, pid) {
        Ok(occupant) -> {
          let occupants = dict.delete(state.occupants, pid)
          let tells = broadcast(occupants, event.PlayerLeft(occupant.name))
          #(State(..state, occupants:), tells)
        }
        Error(_) -> #(state, [])
      }
    }
    Look(pid) ->
      case dict.get(state.occupants, pid) {
        Ok(_) -> #(state, [Tell(pid, you_are_in(state))])
        Error(_) -> #(state, [])
      }
    Say(speaker, text) -> {
      case dict.get(state.occupants, speaker) {
        Ok(occupant) -> {
          let tells = [
            Tell(speaker, event.YouSaid(text:)),
            ..tell_others(
              state.occupants,
              speaker,
              event.PlayerSaid(player_name: occupant.name, text:),
            )
          ]
          #(state, tells)
        }
        Error(_) -> #(state, [])
      }
    }
    Down(Some(pid)) -> decide(state, Leave(pid))
    Down(None) -> #(state, [])
  }
}

fn you_are_in(state: State) -> event.RoomEvent {
  event.YouAreIn(
    room_name: state.def.name,
    room_description: state.def.description,
    exits: list.filter(direction.all(), fn(d) {
      dict.has_key(state.def.exits, d)
    }),
  )
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
  let #(state, actions) = decide(state, message)
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
