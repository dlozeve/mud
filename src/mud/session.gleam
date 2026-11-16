import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mud/command
import mud/event.{type RoomEvent}
import mud/id.{type PlayerId, type RoomId}
import mud/player
import mud/room
import mud/world

// ----- State ------------------------------------------------------------

pub type State {
  State(
    subject: Subject(Message),
    replies: Subject(world.Reply),
    world: process.Name(world.Message),
    entrance: RoomId,
    status: Status,
    buffer: BitArray,
    room_watch: Option(RoomWatch),
  )
}

pub type Status {
  AwaitingName
  Joining(id: PlayerId, name: String)
  InGame(player: player.State)
}

pub type RoomWatch {
  RoomWatch(pid: process.Pid, monitor: process.Monitor)
}

// ----- Message ----------------------------------------------------------

pub type Message {
  RoomMessage(room: RoomId, event: RoomEvent)
  WorldMessage(world.Reply)
  JoinTimeout
  RoomDown(pid: Option(process.Pid))
  RetryEnter(room: room.Def, attempt: Int)
}

// ----- Effect -----------------------------------------------------------

pub type Effect {
  Do(player.Action)
  Join(RoomId)
  EnterRoom(room: room.Def, attempt: Int)
  LeaveRoom(process.Name(room.Message))
  Stop
}

// ----- Logic ------------------------------------------------------------

pub fn started(
  subject: Subject(Message),
  replies: Subject(world.Reply),
  world: process.Name(world.Message),
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
      room_watch: None,
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
    InGame(_) ->
      case state.status {
        InGame(player_state) -> [LeaveRoom(player_state.room.process_name)]
        _ -> []
      }
  }
}

const max_line = 1024

const max_enter_attempts = 10

// for bytes received from the socket
pub fn receive_bytes(state: State, chunk: BitArray) -> #(State, List(Effect)) {
  let #(buffer, lines) = take_lines(state.buffer, chunk)
  let state = State(..state, buffer:)
  case
    list.any(lines, fn(line) { string.byte_size(line) > max_line })
    || bit_array.byte_size(buffer) > max_line
  {
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
        command.Quit -> #(state, [
          LeaveRoom(player_state.room.process_name),
          Stop,
        ])
        parsed -> {
          let #(player_state, actions) =
            player.decide_command(player_state, parsed)
          #(State(..state, status: InGame(player_state)), list.map(actions, Do))
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
    world.AlreadyLoggedIn ->
      "This name is already in use. Choose another name: "
  }
  #(State(..state, status: AwaitingName), [Do(player.Output(msg))])
}

// for messages received from other processes
pub fn receive_message(
  state: State,
  message: Message,
) -> #(State, List(Effect)) {
  case message {
    WorldMessage(reply) -> receive_reply(state, reply)
    RoomMessage(room_id, room_event) ->
      case state.status {
        InGame(player_state) if player_state.room.id == room_id -> {
          let #(player_state, actions) = player.decide(player_state, room_event)
          #(State(..state, status: InGame(player_state)), list.map(actions, Do))
        }
        // Message from a stale room that has not updated its occupancy, ignored.
        InGame(_) -> #(state, [])
        AwaitingName -> #(state, [])
        Joining(_, _) -> #(state, [])
      }
    JoinTimeout ->
      case state.status {
        Joining(_, _) -> #(State(..state, status: AwaitingName), [
          Do(player.Output("The world is not answering, try again: ")),
        ])
        _ -> #(state, [])
      }
    RoomDown(Some(pid)) ->
      case state.status, state.room_watch {
        InGame(player_state), Some(RoomWatch(watched_pid, _))
          if pid == watched_pid
        -> #(State(..state, room_watch: None), [
          EnterRoom(player_state.room, attempt: 0),
        ])
        _, _ -> #(state, [])
      }
    RoomDown(None) -> #(state, [])
    RetryEnter(room, attempt) ->
      case state.status {
        InGame(_) if attempt > max_enter_attempts -> #(state, [
          Do(player.Output("The room is not available. Disconnecting.")),
          Stop,
        ])
        InGame(_) -> #(state, [
          EnterRoom(room, attempt),
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
          let player_state = player.State(id:, name:, room:)
          #(State(..state, status: InGame(player_state)), [
            EnterRoom(room, attempt: 0),
          ])
        }
        AwaitingName -> #(state, [])
        InGame(_) -> #(state, [])
      }
    world.Joined(Error(join_error)) ->
      case state.status {
        Joining(_, _) -> join_failed(state, join_error)
        _ -> #(state, [])
      }
    world.Moved(from, Ok(to_room)) ->
      case state.status {
        InGame(player_state) if player_state.room.id == from -> {
          let from_room = player_state.room
          let new_player_state = player.State(..player_state, room: to_room)
          #(State(..state, status: InGame(new_player_state)), [
            LeaveRoom(from_room.process_name),
            EnterRoom(to_room, attempt: 0),
          ])
        }
        // stale reply, ignore
        InGame(_) -> #(state, [])
        _ -> #(state, [])
      }
    world.Moved(from, Error(_move_error)) ->
      case state.status {
        InGame(player_state) if player_state.room.id == from -> #(state, [
          Do(player.Output("You can't go that way.")),
        ])
        _ -> #(state, [])
      }
  }
}

// ----- Line decoding and handling ---------------------------------------

pub fn take_lines(
  buffer: BitArray,
  chunk: BitArray,
) -> #(BitArray, List(String)) {
  let bytes = bit_array.append(buffer, chunk)
  case bit_array.to_string(bytes) {
    // Fast path: the whole buffer is valid UTF-8, so it can be split as text.
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
    // Either the buffer ends in the middle of a multi-byte character, or a
    // client sent bytes that are not UTF-8 at all. Decoding the whole buffer
    // is impossible, so split it on the newline at the byte level instead:
    // 0x0A can never appear inside a UTF-8 sequence, so this is safe and one
    // bad line cannot hold back the ones after it.
    Error(_) -> take_lines_bytewise(bytes)
  }
}

fn take_lines_bytewise(bytes: BitArray) -> #(BitArray, List(String)) {
  let size = bit_array.byte_size(bytes)
  let #(chunks, rest_at) = split_chunks(bytes, size, 0, 0, [])
  #(
    slice_bytes(bytes, rest_at, size - rest_at),
    list.filter_map(chunks, decode_line),
  )
}

// Walk the bytes, cutting at every 0x0A. Returns the completed chunks (without
// the newline) and the offset where the unterminated remainder starts.
fn split_chunks(
  bytes: BitArray,
  size: Int,
  start: Int,
  at: Int,
  chunks: List(BitArray),
) -> #(List(BitArray), Int) {
  case at >= size {
    True -> #(list.reverse(chunks), start)
    False ->
      case is_newline(bytes, at) {
        True ->
          split_chunks(bytes, size, at + 1, at + 1, [
            slice_bytes(bytes, start, at - start),
            ..chunks
          ])
        False -> split_chunks(bytes, size, start, at + 1, chunks)
      }
  }
}

fn is_newline(bytes: BitArray, at: Int) -> Bool {
  case bit_array.slice(bytes, at, 1) {
    Ok(<<10>>) -> True
    _ -> False
  }
}

fn slice_bytes(bytes: BitArray, at: Int, length: Int) -> BitArray {
  result.unwrap(bit_array.slice(bytes, at, length), <<>>)
}

fn decode_line(chunk: BitArray) -> Result(String, Nil) {
  case bit_array.to_string(chunk) {
    Ok(text) -> clean_line(text)
    // A line that is not valid UTF-8 cannot be a command; drop it.
    Error(_) -> Error(Nil)
  }
}

fn clean_line(line: String) -> Result(String, Nil) {
  case string.replace(line, "\r", "") |> string.trim() {
    // blank lines are ignored
    "" -> Error(Nil)
    clean -> Ok(clean)
  }
}

// ------ Public helpers --------------------------------------------------

fn to_listener(player: Subject(Message)) -> event.Listener {
  event.Listener(fn(room_id, room_event) {
    process.send(player, RoomMessage(room_id, room_event))
  })
}

pub fn to_session(
  player: Subject(Message),
  player_state: player.State,
) -> event.Session {
  event.Session(
    player_state.id,
    player_state.name,
    process.self(),
    to_listener(player),
  )
}
