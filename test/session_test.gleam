import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import mud/direction
import mud/event
import mud/id
import mud/player
import mud/room
import mud/session
import mud/world

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
  state_with_world(process.new_name("world"), status)
}

fn state_with_world(
  world_name: process.Name(world.Message),
  status: session.Status,
) -> session.State {
  session.State(
    subject: process.new_subject(),
    replies: process.new_subject(),
    world: world_name,
    entrance: id.new_room_id("entrance"),
    status: status,
    buffer: <<>>,
    room_watch: None,
  )
}

fn awaiting_name_state() -> session.State {
  state_with(session.AwaitingName)
}

fn joining_state() -> session.State {
  state_with(session.Joining(id.new_player_id("alice"), "Alice"))
}

fn in_game_state() -> session.State {
  in_room_state(room_info("a room"))
}

fn in_room_state(room: room.Def) -> session.State {
  let world_name = process.new_name("world")
  let player_state =
    player.State(
      id: id.new_player_id("alice"),
      name: "Alice",
      world: world_name,
      room: room,
    )
  state_with_world(world_name, session.InGame(player_state))
}

fn effects(r: #(session.State, List(session.Effect))) -> List(session.Effect) {
  let #(_, effects) = r
  effects
}

// ----- Connection start -------------------------------------------------

pub fn started_test() {
  let subject = process.new_subject()
  let replies = process.new_subject()
  let world = process.new_name("world")
  let entrance = id.new_room_id("entrance")
  let #(state, effects) = session.started(subject, replies, world, entrance)
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

pub fn join_failed_test() {
  let state = joining_state()
  let #(new_state, effects) = session.join_failed(state, world.NameTaken)
  assert new_state.status == session.AwaitingName
  assert effects
    == [session.Do(player.Output("Name taken. Choose another name: "))]
}

// ----- In game ----------------------------------------------------------

pub fn receive_bytes_in_game_test() {
  let state = in_game_state()
  let assert session.InGame(player_state) = state.status
  assert session.receive_bytes(state, <<"say hi\n">>) |> effects
    == [session.Do(player.Say("hi"))]
  assert session.receive_bytes(state, <<"quit\n">>) |> effects
    == [session.LeaveRoom(player_state.room.process_name), session.Stop]
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
  let assert session.InGame(player_state) = state.status
  assert session.receive_message(
      state,
      session.RoomMessage(player_state.room.id, event.YouSaid("hi")),
    )
    |> effects
    == [session.Do(player.Output("You say: hi"))]
}

pub fn receive_message_stale_room_test() {
  let state = in_game_state()
  assert session.receive_message(
      state,
      session.RoomMessage(id.new_room_id("somewhere else"), event.YouSaid("hi")),
    )
    |> effects
    == []
}

pub fn receive_message_in_awaiting_name_test() {
  let state = awaiting_name_state()
  assert session.receive_message(
      state,
      session.RoomMessage(state.entrance, event.YouSaid("hi")),
    )
    |> effects
    == []
}

pub fn receive_message_in_joining_test() {
  let state = joining_state()
  assert session.receive_message(
      state,
      session.RoomMessage(state.entrance, event.YouSaid("hi")),
    )
    |> effects
    == []
}

// ----- World replies ----------------------------------------------------

pub fn join_reply_starts_the_game_test() {
  let state = joining_state()
  let entrance = room_info("entrance")

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Joined(Ok(entrance))),
    )

  assert effects == [session.EnterRoom(entrance, 0)]
  assert new_state.status
    == session.InGame(player.State(
      id: id.new_player_id("alice"),
      name: "Alice",
      world: state.world,
      room: entrance,
    ))
}

pub fn join_reply_when_already_in_game_is_ignored_test() {
  let state = in_room_state(room_info("entrance"))
  let corridor = room_info("corridor")

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Joined(Ok(corridor))),
    )

  assert effects == []
  assert new_state.status == state.status
}

pub fn join_error_returns_to_awaiting_name_test() {
  let state = joining_state()

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Joined(Error(world.NoSuchRoom))),
    )

  assert effects == [session.Do(player.Output("This room does not exist."))]
  assert new_state.status == session.AwaitingName
}

pub fn join_name_taken_test() {
  let state = joining_state()

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Joined(Error(world.NameTaken))),
    )

  assert effects
    == [session.Do(player.Output("Name taken. Choose another name: "))]
  assert new_state.status == session.AwaitingName
}

pub fn join_error_when_already_in_game_is_ignored_test() {
  let state = in_room_state(room_info("entrance"))

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Joined(Error(world.NoSuchRoom))),
    )

  // A late error must not demote a player who is already in the game, or the
  // room keeps an occupant that no session knows about.
  assert effects == []
  assert new_state.status == state.status
}

pub fn move_reply_relocates_the_player_test() {
  let entrance = room_info("entrance")
  let corridor = room_info("corridor")
  let state = in_room_state(entrance)

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Moved(entrance.id, Ok(corridor))),
    )

  // The old room is named explicitly: by the time these effects run the player
  // already records the new room.
  assert effects
    == [
      session.LeaveRoom(entrance.process_name),
      session.EnterRoom(corridor, 0),
    ]
  assert new_state.status
    == session.InGame(player.State(
      id: id.new_player_id("alice"),
      name: "Alice",
      world: state.world,
      room: corridor,
    ))
}

pub fn move_reply_from_a_stale_room_is_ignored_test() {
  let entrance = room_info("entrance")
  let corridor = room_info("corridor")
  let elsewhere = room_info("elsewhere")
  let state = in_room_state(corridor)

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Moved(entrance.id, Ok(elsewhere))),
    )

  assert effects == []
  assert new_state.status == state.status
}

pub fn move_error_test() {
  let entrance = room_info("entrance")
  let state = in_room_state(entrance)

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Moved(
        entrance.id,
        Error(world.NonExistingExit),
      )),
    )

  assert effects == [session.Do(player.Output("You can't go that way."))]
  assert new_state.status == state.status
}

pub fn move_error_from_a_stale_room_is_ignored_test() {
  let entrance = room_info("entrance")
  let corridor = room_info("corridor")
  let state = in_room_state(corridor)

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Moved(
        entrance.id,
        Error(world.NonExistingExit),
      )),
    )

  assert effects == []
  assert new_state.status == state.status
}

pub fn join_timeout_returns_to_awaiting_name_test() {
  let state = joining_state()

  let #(new_state, effects) =
    session.receive_message(state, session.JoinTimeout)

  assert effects
    == [session.Do(player.Output("The world is not answering, try again: "))]
  assert new_state.status == session.AwaitingName
}

pub fn join_timeout_while_in_game_is_ignored_test() {
  let state = in_room_state(room_info("entrance"))
  assert session.receive_message(state, session.JoinTimeout) |> effects == []
}

// Two moves in one packet are both dispatched from the room the player was in,
// so the second reply is stale and must not move them a second time.
pub fn second_move_reply_in_the_same_packet_is_ignored_test() {
  let entrance = room_info("entrance")
  let corridor = room_info("corridor")
  let state = in_room_state(entrance)

  let #(dispatched, dispatched_effects) =
    session.receive_bytes(state, <<"go north\ngo north\n">>)
  assert dispatched_effects
    == [
      session.Do(player.Move(direction.North)),
      session.Do(player.Move(direction.North)),
    ]

  let #(moved, first_effects) =
    session.receive_message(
      dispatched,
      session.WorldMessage(world.Moved(entrance.id, Ok(corridor))),
    )
  assert first_effects
    == [
      session.LeaveRoom(entrance.process_name),
      session.EnterRoom(corridor, 0),
    ]

  let #(after, second_effects) =
    session.receive_message(
      moved,
      session.WorldMessage(world.Moved(entrance.id, Ok(corridor))),
    )
  assert second_effects == []
  assert after.status == moved.status
}

// ----- Room restart -----------------------------------------------------

fn watched_state(room: room.Def, pid: process.Pid) -> session.State {
  let state = in_room_state(room)
  session.State(
    ..state,
    room_watch: Some(session.RoomWatch(pid, process.monitor(pid))),
  )
}

pub fn room_down_reenters_the_current_room_test() {
  let entrance = room_info("entrance")
  let me = process.self()
  let state = watched_state(entrance, me)

  let #(new_state, effects) =
    session.receive_message(state, session.RoomDown(Some(me)))

  assert effects == [session.EnterRoom(entrance, 0)]
  assert new_state.room_watch == None
}

pub fn room_down_from_a_room_we_have_left_is_ignored_test() {
  let entrance = room_info("entrance")
  let old_room = process.spawn(fn() { Nil })
  let state = watched_state(entrance, process.self())

  // A monitor of a room we already moved out of fires later and must not
  // pull the player back into their current room.
  let #(new_state, effects) =
    session.receive_message(state, session.RoomDown(Some(old_room)))

  assert effects == []
  assert new_state.status == state.status
}

pub fn room_down_when_not_in_game_is_ignored_test() {
  let state = joining_state()
  assert session.receive_message(state, session.RoomDown(Some(process.self())))
    |> effects
    == []
}

pub fn retry_enter_reemits_enter_room_test() {
  let entrance = room_info("entrance")
  let state = in_room_state(entrance)

  let #(_, effects) =
    session.receive_message(state, session.RetryEnter(entrance, 1))

  assert effects == [session.EnterRoom(entrance, 1)]
}

pub fn retry_enter_gives_up_after_max_attempts_test() {
  let entrance = room_info("entrance")
  let state = in_room_state(entrance)

  let #(_, effects) =
    session.receive_message(state, session.RetryEnter(entrance, 11))

  assert effects
    == [
      session.Do(player.Output("The room is not available. Disconnecting.")),
      session.Stop,
    ]
}

pub fn retry_enter_when_not_in_game_is_ignored_test() {
  let state = joining_state()
  assert session.receive_message(
      state,
      session.RetryEnter(room_info("entrance"), 1),
    )
    |> effects
    == []
}

// ----- Disconnecting ----------------------------------------------------

pub fn closed_test() {
  let state = in_game_state()
  let assert session.InGame(player_state) = state.status
  assert session.closed(state)
    == [session.LeaveRoom(player_state.room.process_name)]
}

pub fn closed_in_awaiting_name_test() {
  assert session.closed(awaiting_name_state()) == []
}

pub fn closed_in_joining_test() {
  assert session.closed(joining_state()) == []
}

pub fn to_session_test() {
  let s = in_game_state()
  let assert session.InGame(player_state) = s.status
  let sess = session.to_session(process.new_subject(), player_state)
  assert sess.id == player_state.id
  assert sess.name == player_state.name
}
