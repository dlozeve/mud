import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
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
}

// ----- Action -----------------------------------------------------------

pub type Action {
  Tell(player: PlayerId, room_event: event.RoomEvent)
}

// ----- Logic ------------------------------------------------------------

pub fn decide(state: State, message: Message) -> #(State, List(Action)) {
  case message {
    Enter(session) -> {
      case dict.get(state.occupants, session.id) {
        Ok(_) -> #(state, [])
        Error(_) -> {
          let occupants = dict.insert(state.occupants, session.id, session)
          let tells = [
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
          #(State(..state, occupants:), tells)
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
        Ok(session) -> session.listener.tell(room_event)
        Error(_) -> Nil
      }
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

pub fn enter(room: process.Name(Message), session: event.Session) -> Nil {
  actor.send(process.named_subject(room), Enter(session))
}

pub fn leave(room: process.Name(Message), player: PlayerId) -> Nil {
  actor.send(process.named_subject(room), Leave(player:))
}

pub fn look(room: process.Name(Message), player: PlayerId) -> Nil {
  actor.send(process.named_subject(room), Look(player:))
}

pub fn say(
  room: process.Name(Message),
  speaker: PlayerId,
  text: String,
) -> Nil {
  actor.send(process.named_subject(room), Say(speaker:, text:))
}
