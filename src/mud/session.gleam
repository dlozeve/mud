import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import mud/command
import mud/event
import mud/player
import mud/room
import mud/world

// ----- State ------------------------------------------------------------

pub type State {
  State(
    subject: Subject(Message),
    replies: Subject(world.Reply),
    world: process.Name(world.Message),
    entrance: room.Id,
    status: Status,
    buffer: BitArray,
    room_watch: Option(RoomWatch),
  )
}

pub type Status {
  AwaitingName
  Joining(name: String)
  InGame(player: player.State)
}

pub type RoomWatch {
  RoomWatch(pid: process.Pid, monitor: process.Monitor)
}

// ----- Message ----------------------------------------------------------

pub type Message {
  RoomMessage(room: room.Id, event: event.RoomEvent)
  WorldMessage(world.Reply)
  JoinTimeout
  RoomDown(pid: Option(process.Pid))
  RetryEnter(room: room.Def, attempt: Int)
}

// ----- Effect -----------------------------------------------------------

pub type Effect {
  Do(player.Action)
  Join(room.Id)
  EnterRoom(room: room.Def, attempt: Int)
  LeaveRoom(process.Name(room.Message))
  AnnounceDeath(process.Name(room.Message), process.Pid)
  Stop
}

// ----- Logic ------------------------------------------------------------

pub fn started(
  subject: Subject(Message),
  replies: Subject(world.Reply),
  world: process.Name(world.Message),
  entrance: room.Id,
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
    Joining(_) -> []
    InGame(player_state) -> [LeaveRoom(player_state.room.process_name)]
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
        Ok(name) -> #(State(..state, status: Joining(name)), [
          Join(state.entrance),
        ])
      }
    }
    Joining(_) -> #(state, [])
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
  let assert Ok(re) =
    regexp.from_string("^[a-zA-Z][a-zA-Z0-9_-]{0,30}[a-zA-Z0-9]$")
  case regexp.check(line, with: re) {
    True ->
      case command.parse(line) {
        command.Unknown(_) -> Ok(line)
        // Valid commands are not valid names
        command.Help
        | command.Say(_)
        | command.Go(_)
        | command.Look
        | command.WhoIsHere
        | command.Attack(_)
        | command.Quit
        | command.BadDirection(_)
        | command.MissingDirection
        | command.MissingTarget -> Error(Nil)
      }
    False -> Error(Nil)
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
          #(
            State(..state, status: InGame(player_state)),
            player_effects(player_state, actions),
          )
        }
        // Message from a stale room that has not updated its occupancy, ignored.
        InGame(_) -> #(state, [])
        AwaitingName -> #(state, [])
        Joining(_) -> #(state, [])
      }
    JoinTimeout ->
      case state.status {
        Joining(_) -> #(State(..state, status: AwaitingName), [
          Do(player.Output("The world is not answering, try again: ")),
        ])
        AwaitingName | InGame(_) -> #(state, [])
      }
    RoomDown(Some(pid)) ->
      case state.status, state.room_watch {
        InGame(player_state), Some(RoomWatch(watched_pid, _))
          if pid == watched_pid
        -> #(State(..state, room_watch: None), [
          EnterRoom(player_state.room, attempt: 0),
        ])
        InGame(_), Some(RoomWatch(..)) -> #(state, [])
        InGame(_), None -> #(state, [])
        AwaitingName, _ -> #(state, [])
        Joining(_), _ -> #(state, [])
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
        AwaitingName | Joining(_) -> #(state, [])
      }
  }
}

fn receive_reply(state: State, reply: world.Reply) -> #(State, List(Effect)) {
  case reply {
    world.Joined(Ok(room)) ->
      case state.status {
        Joining(name:) -> {
          let player_state = player.new(process.self(), name, room)
          #(State(..state, status: InGame(player_state)), [
            EnterRoom(room, attempt: 0),
          ])
        }
        AwaitingName -> #(state, [])
        InGame(_) -> #(state, [])
      }
    world.Joined(Error(join_error)) ->
      case state.status {
        Joining(_) -> join_failed(state, join_error)
        AwaitingName | InGame(_) -> #(state, [])
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
        AwaitingName | Joining(_) -> #(state, [])
      }
    world.Moved(from, Error(_move_error)) ->
      case state.status {
        InGame(player_state) if player_state.room.id == from -> #(state, [
          Do(player.Output("You can't go that way.")),
        ])
        InGame(_) | AwaitingName | Joining(_) -> #(state, [])
      }
  }
}

// A `Die` action is a session-level event: the player is told, the room is
// told to broadcast the death, and the connection stops.
fn player_effects(
  player_state: player.State,
  actions: List(player.Action),
) -> List(Effect) {
  let died = list.any(actions, fn(action) { action == player.Die })
  let effects =
    actions
    |> list.filter(fn(action) { action != player.Die })
    |> list.map(Do)
  case died {
    True ->
      list.append(effects, [
        AnnounceDeath(player_state.room.process_name, player_state.pid),
        Stop,
      ])
    False -> effects
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

// The room's handle on this player: it tells the player about room events by
// posting them into the connection's own inbox.
pub fn to_occupant(state: State, player_state: player.State) -> room.Occupant {
  room.occupant(
    player_state.name,
    player_state.pid,
    event.Player,
    fn(room_id, room_event) {
      process.send(state.subject, RoomMessage(room_id, room_event))
    },
  )
}
