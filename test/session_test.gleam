import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/string
import mud/direction
import mud/event
import mud/id
import mud/player
import mud/room
import mud/session

// ----- Line decoding ----------------------------------------------------

pub fn take_lines_no_lf_test() {
  assert session.take_lines(<<>>, <<"say hi">>) == #(<<"say hi">>, [])
}

pub fn take_lines_test() {
  assert session.take_lines(<<"say hi">>, <<"\n">>) == #(<<>>, ["say hi"])
}

pub fn take_lines_strip_cr_test() {
  assert session.take_lines(<<>>, <<"look\r\nsay hi\n">>)
    == #(<<>>, ["look", "say hi"])
}

pub fn take_lines_empty_test() {
  assert session.take_lines(<<>>, <<"\n\n">>) == #(<<>>, [])
}

pub fn take_lines_utf8_split_across_chunks_test() {
  assert session.take_lines(<<195>>, <<169, 10>>) == #(<<>>, ["é"])
}

// ----- Helpers ----------------------------------------------------------

fn room_info(name: String) -> room.Def {
  room.Def(
    process_name: process.new_name(name),
    id: id.new_room_id(name),
    name: name,
    description: name <> " description",
    exits: dict.new(),
  )
}

fn state_with(status: session.Status) -> session.State {
  session.State(
    subject: process.new_subject(),
    world: process.new_subject(),
    entrance: id.new_room_id("entrance"),
    status: status,
    buffer: <<>>,
  )
}

fn awaiting_name_state() -> session.State {
  state_with(session.AwaitingName)
}

fn joining_state() -> session.State {
  state_with(session.Joining(id.new_player_id("alice"), "Alice"))
}

fn in_game_state() -> session.State {
  let player_state =
    player.State(
      id: id.new_player_id("alice"),
      name: "Alice",
      world: process.new_subject(),
      room: room_info("a room"),
    )
  state_with(session.InGame(player_state))
}

fn effects(r: #(session.State, List(session.Effect))) -> List(session.Effect) {
  let #(_, effects) = r
  effects
}

// ----- Connection start -------------------------------------------------

pub fn started_test() {
  let subject = process.new_subject()
  let world = process.new_subject()
  let entrance = id.new_room_id("entrance")
  let #(state, effects) = session.started(subject, world, entrance)
  assert effects
    == [session.Do(player.Output("Welcome to the dungeon! What is your name?"))]
  assert state.status == session.AwaitingName
  assert state.buffer == <<>>
  assert state.entrance == entrance
}

// ----- Naming and joining -----------------------------------------------

pub fn receive_bytes_awaiting_name_test() {
  let state = awaiting_name_state()
  let #(new_state, effects) = session.receive_bytes(state, <<"Alice\n">>)

  // The session no longer knows the room: the world answers the Join.
  assert effects == [session.Join(state.entrance)]
  assert new_state.status
    == session.Joining(id: id.new_player_id("alice"), name: "Alice")
}

pub fn receive_bytes_invalid_name_test() {
  let state = awaiting_name_state()
  let #(new_state, effects) =
    session.receive_bytes(state, <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n">>)
  assert effects == [session.Do(player.Output("Invalid name, try again:"))]
  assert new_state.status == session.AwaitingName
}

pub fn receive_bytes_while_joining_is_ignored_test() {
  let state = joining_state()
  assert session.receive_bytes(state, <<"look\n">>) |> effects == []
}

// TODO: the message is wrong for NoSuchRoom (review §4 B5).
pub fn join_failed_test() {
  let state = joining_state()
  let #(new_state, effects) = session.join_failed(state)
  assert new_state.status == session.AwaitingName
  assert effects
    == [session.Do(player.Output("Name taken. Choose another name: "))]
}

// ----- In game ----------------------------------------------------------

pub fn receive_bytes_in_game_test() {
  let state = in_game_state()
  assert session.receive_bytes(state, <<"say hi\n">>) |> effects
    == [session.Do(player.Say("hi"))]
  assert session.receive_bytes(state, <<"quit\n">>) |> effects
    == [session.Do(player.Leave), session.Stop]
  assert session.receive_bytes(state, <<"look\n">>)
    |> effects
    == [session.Do(player.Look)]
  assert session.receive_bytes(state, <<"go north\n">>)
    |> effects
    == [session.Do(player.Move(direction.North))]
  assert session.receive_bytes(state, <<"something\n">>)
    |> effects
    == [session.Do(player.Unknown("something"))]
}

pub fn receive_bytes_line_too_long_test() {
  let state = in_game_state()
  let line = string.repeat("a", times: 1025)
  assert session.receive_bytes(state, bit_array.from_string(line))
    |> effects
    == [session.Do(player.Output("Line too long.")), session.Stop]
}

pub fn receive_message_test() {
  let state = in_game_state()
  assert session.receive_message(state, player.Event(event.YouSaid("hi")))
    |> effects
    == [session.Do(player.Output("You say: hi"))]
}

pub fn receive_message_in_awaiting_name_test() {
  let state = awaiting_name_state()
  assert session.receive_message(state, player.Event(event.YouSaid("hi")))
    |> effects
    == []
}

pub fn receive_message_in_joining_test() {
  let state = joining_state()
  assert session.receive_message(state, player.Event(event.YouSaid("hi")))
    |> effects
    == []
}

// ----- Disconnecting ----------------------------------------------------

pub fn closed_test() {
  assert session.closed(in_game_state()) == [session.Do(player.Leave)]
}

pub fn closed_in_awaiting_name_test() {
  assert session.closed(awaiting_name_state()) == []
}

pub fn closed_in_joining_test() {
  assert session.closed(joining_state()) == []
}
