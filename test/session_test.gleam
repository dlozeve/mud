import gleam/bit_array
import gleam/erlang/process
import gleam/string
import mud/direction
import mud/event
import mud/id
import mud/player
import mud/session

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

pub fn started_test() {
  let subject = process.new_subject()
  let world = process.new_subject()
  let r1 = id.new_room_id("r1")
  let #(state, effects) = session.started(subject, world, r1)
  assert effects
    == [session.Do(player.Output("Welcome to the dungeon! What is your name?"))]
  assert state.status == session.AwaitingName
  assert state.buffer == <<>>
  assert state.entrance == r1
}

fn awaiting_name_state() {
  let subject = process.new_subject()
  let world = process.new_subject()
  let r1 = id.new_room_id("r1")
  session.State(
    subject:,
    world:,
    entrance: r1,
    status: session.AwaitingName,
    buffer: <<>>,
  )
}

pub fn receive_bytes_awaiting_name_test() {
  let state = awaiting_name_state()
  let #(new_state, effects) = session.receive_bytes(state, <<"Alice\n">>)
  assert effects
    == [
      session.Join(
        player.to_session(
          state.subject,
          player.State(id.new_player_id("alice"), "Alice", state.world),
        ),
        state.entrance,
      ),
    ]
  assert new_state.status
    == session.InGame(player.State(
      id.new_player_id("alice"),
      "Alice",
      state.world,
    ))
}

pub fn receive_bytes_invalid_name_test() {
  let state = awaiting_name_state()
  let #(new_state, effects) =
    session.receive_bytes(state, <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n">>)
  assert effects == [session.Do(player.Output("Invalid name, try again:"))]
  assert new_state.status == session.AwaitingName
}

fn effects(r: #(session.State, List(session.Effect))) -> List(session.Effect) {
  let #(_, effects) = r
  effects
}

pub fn in_game_state() -> session.State {
  let subject = process.new_subject()
  let world = process.new_subject()
  let r1 = id.new_room_id("r1")
  let player_state =
    player.State(id: id.new_player_id("alice"), name: "Alice", world: world)
  session.State(
    subject:,
    world:,
    entrance: r1,
    status: session.InGame(player_state),
    buffer: <<>>,
  )
}

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
  let s = string.repeat("a", times: 1025)
  assert session.receive_bytes(state, bit_array.from_string(s))
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

pub fn closed_test() {
  let state = in_game_state()
  assert session.closed(state) == [session.Do(player.Leave)]
}

pub fn closed_in_awaiting_name_test() {
  let state = awaiting_name_state()
  assert session.closed(state) == []
}
