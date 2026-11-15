import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import mud/command
import mud/id.{type PlayerId, type RoomId}
import mud/player
import mud/world

// ----- State ------------------------------------------------------------

pub type State {
  State(
    subject: Subject(player.Message),
    replies: Subject(world.Reply),
    world: Subject(world.Message),
    entrance: RoomId,
    status: Status,
    buffer: BitArray,
  )
}

pub type Status {
  AwaitingName
  Joining(id: PlayerId, name: String)
  InGame(player: player.State)
}

// ----- Effect -----------------------------------------------------------

pub type Effect {
  Do(player.Action)
  Join(RoomId)
  Stop
}

// ----- Logic ------------------------------------------------------------

pub fn started(
  subject: Subject(player.Message),
  replies: Subject(world.Reply),
  world: Subject(world.Message),
  entrance: RoomId,
) -> #(State, List(Effect)) {
  let state =
    State(
      subject:,
      replies:,
      world:,
      entrance: entrance,
      status: AwaitingName,
      buffer: <<>>,
    )
  let effects = [
    Do(player.Output("Welcome to the dungeon! What is your name?")),
  ]
  #(state, effects)
}

pub fn closed(state: State) -> List(Effect) {
  case state.status {
    AwaitingName -> []
    Joining(_, _) -> []
    InGame(_) -> [Do(player.Leave)]
  }
}

const max_line = 1024

// for bytes received from the socket
pub fn receive_bytes(state: State, chunk: BitArray) -> #(State, List(Effect)) {
  let #(buffer, lines) = take_lines(state.buffer, chunk)
  let state = State(..state, buffer:)
  case bit_array.byte_size(buffer) > max_line {
    True -> #(state, [Do(player.Output("Line too long.")), Stop])
    False ->
      // effects after Stop are ignored
      list.fold(lines, #(state, []), fn(acc, line) {
        let #(state, effects) = acc
        let #(new_state, new_effects) = handle_line(state, line)
        #(new_state, list.append(effects, new_effects))
      })
  }
}

fn handle_line(state: State, line: String) -> #(State, List(Effect)) {
  case state.status {
    AwaitingName -> {
      case valid_name(line) {
        Error(_) -> #(state, [Do(player.Output("Invalid name, try again:"))])
        Ok(name) -> {
          let new_status =
            Joining(id.new_player_id(string.lowercase(name)), name)
          #(State(..state, status: new_status), [Join(state.entrance)])
        }
      }
    }
    Joining(_, _) -> #(state, [])
    InGame(player_state) ->
      case command.parse(line) {
        command.Quit -> {
          let #(_, actions) = player.decide_command(player_state, command.Quit)
          #(state, list.append(list.map(actions, Do), [Stop]))
        }
        parsed -> {
          let #(_, actions) = player.decide_command(player_state, parsed)
          #(state, list.map(actions, Do))
        }
      }
  }
}

fn valid_name(line: String) -> Result(String, Nil) {
  case string.length(line) {
    0 -> Error(Nil)
    n if n > 32 -> Error(Nil)
    _ -> Ok(line)
  }
}

pub fn join_failed(
  state: State,
  error: world.JoinError,
) -> #(State, List(Effect)) {
  let msg = case error {
    world.NoSuchRoom -> "This room does not exist."
    world.NameTaken -> "Name taken. Choose another name: "
  }
  #(State(..state, status: AwaitingName), [Do(player.Output(msg))])
}

// for messages received from other processes
pub fn receive_message(
  state: State,
  message: player.Message,
) -> #(State, List(Effect)) {
  case message {
    player.WorldMessage(reply) -> receive_reply(state, reply)
    player.RoomMessage(room_event) ->
      case state.status {
        AwaitingName -> #(state, [])
        Joining(_, _) -> #(state, [])
        InGame(player_state) -> {
          let #(_, actions) = player.decide(player_state, room_event)
          #(state, list.map(actions, Do))
        }
      }
    player.JoinTimeout ->
      case state.status {
        Joining(_, _) -> #(state, [
          Do(player.Output("The world is not answering, try again.")),
        ])
        _ -> #(state, [])
      }
  }
}

fn receive_reply(state: State, reply: world.Reply) -> #(State, List(Effect)) {
  case reply {
    world.Joined(Ok(room)) ->
      case state.status {
        Joining(id:, name:) -> {
          let player_state = player.State(id:, name:, room:, world: state.world)
          #(State(..state, status: InGame(player_state)), [
            Do(player.EnterRoom(room)),
          ])
        }
        AwaitingName -> #(state, [])
        InGame(_) -> #(state, [])
      }
    world.Joined(Error(join_error)) -> join_failed(state, join_error)
    world.Moved(Ok(to_room)) ->
      case state.status {
        InGame(player_state) -> {
          let from_room = player_state.room
          let new_player_state = player.State(..player_state, room: to_room)
          #(State(..state, status: InGame(new_player_state)), [
            Do(player.LeaveRoom(from_room.process_name)),
            Do(player.EnterRoom(to_room)),
          ])
        }
        _ -> #(state, [])
      }
    world.Moved(Error(_move_error)) -> #(state, [
      Do(player.Output("You can't go that way.")),
    ])
  }
}

// ----- Line decoding and handling ---------------------------------------

pub fn take_lines(
  buffer: BitArray,
  chunk: BitArray,
) -> #(BitArray, List(String)) {
  let bytes = bit_array.append(buffer, chunk)
  case bit_array.to_string(bytes) {
    // Not valid UTF-8 yet: a character is split across chunks, keep waiting.
    Error(_) -> #(bytes, [])
    Ok(text) -> {
      case string.split(text, "\n") {
        [] -> #(bytes, [])
        parts -> {
          let #(complete, rest) = list.split(parts, list.length(parts) - 1)
          #(
            bit_array.from_string(string.concat(rest)),
            list.filter_map(complete, clean_line),
          )
        }
      }
    }
  }
}

fn clean_line(line: String) -> Result(String, Nil) {
  case string.replace(line, "\r", "") |> string.trim() {
    // blank lines are ignored
    "" -> Error(Nil)
    clean -> Ok(clean)
  }
}
