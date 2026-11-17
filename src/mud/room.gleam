import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import mud/direction.{type Direction}
import mud/event
import mud/id.{type RoomId}

// ----- State ------------------------------------------------------------

// Occupants are keyed by their connection pid.
pub type State {
  State(def: Def, occupants: Dict(process.Pid, event.Session))
}

pub type Def {
  Def(
    process_name: process.Name(Message),
    id: RoomId,
    name: String,
    description: String,
    exits: Dict(Direction, RoomId),
  )
}

// ----- Message ----------------------------------------------------------

pub type Message {
  Enter(session: event.Session)
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
    Enter(session) -> {
      case dict.get(state.occupants, session.pid) {
        Ok(_) -> #(state, [])
        Error(_) -> {
          let occupants = dict.insert(state.occupants, session.pid, session)
          let actions = [
            Monitor(session.pid),
            Tell(
              session.pid,
              event.YouAreIn(
                room_name: state.def.name,
                room_description: state.def.description,
                exits: list.filter(direction.all(), fn(d) {
                  dict.has_key(state.def.exits, d)
                }),
              ),
            ),
            ..tell_others(
              occupants,
              session.pid,
              event.PlayerArrived(session.name),
            )
          ]
          #(State(..state, occupants:), actions)
        }
      }
    }
    Leave(pid) -> {
      case dict.get(state.occupants, pid) {
        Ok(session) -> {
          let occupants = dict.delete(state.occupants, pid)
          let tells = broadcast(occupants, event.PlayerLeft(session.name))
          #(State(..state, occupants:), tells)
        }
        Error(_) -> #(state, [])
      }
    }
    Look(player) ->
      case dict.get(state.occupants, player) {
        Ok(session) -> {
          let tell =
            Tell(
              session.pid,
              event.YouAreIn(
                room_name: state.def.name,
                room_description: state.def.description,
                exits: list.filter(direction.all(), fn(d) {
                  dict.has_key(state.def.exits, d)
                }),
              ),
            )
          #(state, [tell])
        }
        Error(_) -> #(state, [])
      }
    Say(speaker, text) -> {
      case dict.get(state.occupants, speaker) {
        Ok(session) -> {
          let tells = [
            Tell(session.pid, event.YouSaid(text:)),
            ..tell_others(
              state.occupants,
              session.pid,
              event.PlayerSaid(player_name: session.name, text:),
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

fn broadcast(
  occupants: Dict(process.Pid, event.Session),
  room_event: event.RoomEvent,
) -> List(Action) {
  occupants
  |> dict.keys
  |> list.map(Tell(_, room_event))
}

fn tell_others(
  occupants: Dict(process.Pid, event.Session),
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

pub fn enter(room_name: process.Name(Message), session: event.Session) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Enter(session))
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
