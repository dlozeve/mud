import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import mud/direction.{type Direction}
import mud/event
import mud/id.{type PlayerId, type RoomId}

// ----- State ------------------------------------------------------------

pub type State {
  State(def: Def, occupants: Dict(PlayerId, event.Session))
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
  Leave(player: PlayerId)
  Look(player: PlayerId)
  Say(speaker: PlayerId, text: String)
  Down(pid: Option(process.Pid))
}

// ----- Action -----------------------------------------------------------

pub type Action {
  Tell(player: PlayerId, room_event: event.RoomEvent)
  Monitor(pid: process.Pid)
}

// ----- Logic ------------------------------------------------------------

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Enter(session) -> {
      case dict.get(state.occupants, session.id) {
        Ok(_) -> #(state, [])
        Error(_) -> {
          let occupants = dict.insert(state.occupants, session.id, session)
          let actions = [
            Monitor(session.pid),
            Tell(
              session.id,
              event.YouAreIn(
                room_name: state.def.name,
                room_description: state.def.description,
                exits: dict.keys(state.def.exits),
              ),
            ),
            ..tell_others(
              occupants,
              session.id,
              event.PlayerArrived(session.name),
            )
          ]
          #(State(..state, occupants:), actions)
        }
      }
    }
    Leave(player) -> {
      case dict.get(state.occupants, player) {
        Ok(session) -> {
          let occupants = dict.delete(state.occupants, player)
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
              session.id,
              event.YouAreIn(
                room_name: state.def.name,
                room_description: state.def.description,
                exits: dict.keys(state.def.exits),
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
            Tell(session.id, event.YouSaid(text:)),
            ..tell_others(
              state.occupants,
              session.id,
              event.PlayerSaid(player_name: session.name, text:),
            )
          ]
          #(state, tells)
        }
        Error(_) -> #(state, [])
      }
    }
    Down(Some(pid)) ->
      case
        dict.to_list(state.occupants) |> list.find(fn(e) { e.1.pid == pid })
      {
        Ok(#(player_id, _session)) -> decide(state, Leave(player_id))
        Error(_) -> #(state, [])
      }
    Down(None) -> #(state, [])
  }
}

fn broadcast(
  occupants: Dict(PlayerId, event.Session),
  room_event: event.RoomEvent,
) -> List(Action) {
  occupants
  |> dict.keys
  |> list.map(Tell(_, room_event))
}

fn tell_others(
  occupants: Dict(PlayerId, event.Session),
  except: PlayerId,
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
    Tell(player, room_event) -> {
      case dict.get(state.occupants, player) {
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

pub fn leave(room_name: process.Name(Message), player: PlayerId) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Leave(player:))
    Error(_) -> Nil
  }
}

pub fn look(room_name: process.Name(Message), player: PlayerId) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Look(player:))
    Error(_) -> Nil
  }
}

pub fn say(
  room_name: process.Name(Message),
  speaker: PlayerId,
  text: String,
) -> Nil {
  case checked_named_subject(room_name) {
    Ok(subject) -> actor.send(subject, Say(speaker:, text:))
    Error(_) -> Nil
  }
}
