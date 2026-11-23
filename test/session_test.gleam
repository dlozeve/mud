import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import mud/direction
import mud/event
import mud/player
import mud/room
import mud/session
import mud/world

// ----- Line decoding ----------------------------------------------------

pub fn take_lines_no_lf_test() -> Nil {
  assert session.take_lines(<<>>, <<"say hi">>) == #(<<"say hi">>, [])
}

pub fn take_lines_test() -> Nil {
  assert session.take_lines(<<"say hi">>, <<"\n">>) == #(<<>>, ["say hi"])
}

pub fn take_lines_strip_cr_test() -> Nil {
  assert session.take_lines(<<>>, <<"look\r\nsay hi\n">>)
    == #(<<>>, ["look", "say hi"])
}

pub fn take_lines_invalid_utf8_does_not_block_later_lines_test() -> Nil {
  // The middle line is not valid UTF-8. It is dropped, but the lines around it
  // must still be processed: one bad line cannot stall the connection.
  assert session.take_lines(<<>>, <<"look\n", 255, "\nsay hi\n">>)
    == #(<<>>, ["look", "say hi"])
}

pub fn take_lines_partial_character_at_the_end_does_not_block_later_lines_test() -> Nil {
  // 195 starts a two-byte character; the complete line before it is not held back.
  assert session.take_lines(<<>>, <<"look\n", 195>>) == #(<<195>>, ["look"])
}

pub fn take_lines_split_character_is_buffered_test() -> Nil {
  assert session.take_lines(<<195>>, <<169>>) == #(<<195, 169>>, [])
}

pub fn take_lines_empty_test() -> Nil {
  assert session.take_lines(<<>>, <<"\n\n">>) == #(<<>>, [])
}

pub fn take_lines_utf8_split_across_chunks_test() -> Nil {
  assert session.take_lines(<<195>>, <<169, 10>>) == #(<<>>, ["é"])
}

// ----- Helpers ----------------------------------------------------------

fn room_info(name: String) -> room.Def {
  room.Def(
    process_name: process.new_name(name),
    id: room.new_id(name),
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
    entrance: room.new_id("entrance"),
    status: status,
    buffer: <<>>,
  )
}

fn awaiting_name_state() -> session.State {
  state_with(session.AwaitingName)
}

fn joining_state() -> session.State {
  state_with(session.Joining("Alice"))
}

fn in_game_state() -> session.State {
  in_room_state(room_info("a room"))
}

fn in_room_state(room: room.Def) -> session.State {
  let world_name = process.new_name("world")
  let player_state = player.new(process.self(), "Alice", room)
  state_with_world(world_name, session.InGame(player_state, room_watch: None))
}

fn effects(r: #(session.State, List(session.Effect))) -> List(session.Effect) {
  let #(_, effects) = r
  effects
}

// ----- Connection start -------------------------------------------------

pub fn started_test() -> Nil {
  let subject = process.new_subject()
  let replies = process.new_subject()
  let world = process.new_name("world")
  let entrance = room.new_id("entrance")
  let #(state, effects) = session.started(subject, replies, world, entrance)
  assert effects
    == [session.Do(player.Output("Welcome to the dungeon! What is your name?"))]
  assert state.status == session.AwaitingName
  assert state.buffer == <<>>
  assert state.entrance == entrance
}

// ----- Naming and joining -----------------------------------------------

pub fn receive_bytes_awaiting_name_test() -> Nil {
  let state = awaiting_name_state()
  let #(new_state, effects) = session.receive_bytes(state, <<"Alice\n">>)

  // The session no longer knows the room: the world answers the Join.
  assert effects == [session.Join(state.entrance)]
  let assert session.Joining(name) = new_state.status
  assert name == "Alice"
}

pub fn receive_bytes_invalid_name_too_long_test() -> Nil {
  let state = awaiting_name_state()
  let #(new_state, effects) =
    session.receive_bytes(state, <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n">>)
  assert effects == [session.Do(player.Output("Invalid name, try again:"))]
  assert new_state.status == session.AwaitingName
}

pub fn receive_bytes_invalid_name_bad_characters_test() -> Nil {
  let state = awaiting_name_state()
  let #(new_state, effects) =
    session.receive_bytes(state, <<"hello, world!\n">>)
  assert effects == [session.Do(player.Output("Invalid name, try again:"))]
  assert new_state.status == session.AwaitingName
}

pub fn receive_bytes_invalid_name_alphanumeric_only_test() -> Nil {
  let state = awaiting_name_state()
  let #(new_state, effects) = session.receive_bytes(state, <<"_Alice_\n">>)
  assert effects == [session.Do(player.Output("Invalid name, try again:"))]
  assert new_state.status == session.AwaitingName
}

pub fn receive_bytes_invalid_name_forbidden_test() -> Nil {
  let state = awaiting_name_state()
  let #(new_state, effects) = session.receive_bytes(state, <<"QUIT\n">>)
  assert effects == [session.Do(player.Output("Invalid name, try again:"))]
  assert new_state.status == session.AwaitingName
}

pub fn receive_bytes_while_joining_is_ignored_test() -> Nil {
  let state = joining_state()
  assert session.receive_bytes(state, <<"look\n">>) |> effects == []
}

pub fn join_failed_test() -> Nil {
  let state = joining_state()
  let #(new_state, effects) =
    session.join_failed(state, world.AlreadyLoggedIn("Alice"))
  assert new_state.status == session.AwaitingName
  assert effects
    == [
      session.Do(player.Output(
        "The name Alice is already in use. Choose another name: ",
      )),
    ]
}

// ----- In game ----------------------------------------------------------

pub fn receive_bytes_in_game_test() -> Nil {
  let state = in_game_state()
  let assert session.InGame(player_state, _) = state.status
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
    == [session.Do(player.Output("Unknown command: something"))]
  assert session.receive_bytes(state, <<"attack a goblin\n">>)
    |> effects
    == [session.Do(player.Attack("a goblin"))]
  assert session.receive_bytes(state, <<"attack\n">>)
    |> effects
    == [session.Do(player.Output("Attack what?"))]
}

pub fn receive_bytes_line_too_long_test() -> Nil {
  let state = in_game_state()
  let line = string.repeat("a", times: 1025)
  assert session.receive_bytes(state, bit_array.from_string(line))
    |> effects
    == [session.Do(player.Output("Line too long.")), session.Stop]
}

pub fn receive_bytes_long_line_ending_with_newline_test() -> Nil {
  let state = in_game_state()
  let line = string.repeat("a", times: 2000)
  assert session.receive_bytes(state, bit_array.from_string(line <> "\n"))
    |> effects
    == [session.Do(player.Output("Line too long.")), session.Stop]
}

pub fn receive_bytes_incomplete_line_under_limit_is_buffered_test() -> Nil {
  let state = in_game_state()
  let chunk = bit_array.from_string(string.repeat("a", times: 600))
  let #(new_state, effects) = session.receive_bytes(state, chunk)
  assert effects == []
  assert bit_array.byte_size(new_state.buffer) == 600
}

pub fn receive_bytes_incomplete_line_over_limit_test() -> Nil {
  let state = in_game_state()
  let chunk = bit_array.from_string(string.repeat("a", times: 1100))
  assert session.receive_bytes(state, chunk) |> effects
    == [session.Do(player.Output("Line too long.")), session.Stop]
}

pub fn receive_message_test() -> Nil {
  let state = in_game_state()
  let assert session.InGame(player_state, _) = state.status
  assert session.receive_message(
      state,
      session.RoomMessage(player_state.room.id, event.YouSaid("hi")),
    )
    |> effects
    == [session.Do(player.Output("You say: hi"))]
}

pub fn receive_message_stale_room_test() -> Nil {
  let state = in_game_state()
  assert session.receive_message(
      state,
      session.RoomMessage(room.new_id("stale room"), event.YouSaid("hi")),
    )
    |> effects
    == []
}

pub fn receive_message_in_awaiting_name_test() -> Nil {
  let state = awaiting_name_state()
  assert session.receive_message(
      state,
      session.RoomMessage(state.entrance, event.YouSaid("hi")),
    )
    |> effects
    == []
}

pub fn receive_message_in_joining_test() -> Nil {
  let state = joining_state()
  assert session.receive_message(
      state,
      session.RoomMessage(state.entrance, event.YouSaid("hi")),
    )
    |> effects
    == []
}

// ----- Combat -----------------------------------------------------------

pub fn receive_message_damage_reduces_hp_test() -> Nil {
  let state = in_game_state()
  let assert session.InGame(player_state, _) = state.status

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.RoomMessage(player_state.room.id, event.NpcHitYou("a goblin", 10)),
    )

  assert effects
    == [
      session.Do(player.Output("A goblin hits you for 10 damage.")),
      session.Do(player.Output("You have 90/100 hp.")),
    ]
  let assert session.InGame(new_player_state, _) = new_state.status
  assert new_player_state.health == player.Alive(90)
}

pub fn receive_message_lethal_damage_dies_and_announces_test() -> Nil {
  let state = in_game_state()
  let assert session.InGame(player_state, _) = state.status

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.RoomMessage(
        player_state.room.id,
        event.NpcHitYou("a goblin", 100),
      ),
    )

  assert effects
    == [
      session.Do(player.Output("You died")),
      session.AnnounceDeath(player_state.room.process_name, player_state.pid),
      session.Stop,
    ]
  let assert session.InGame(new_player_state, _) = new_state.status
  assert new_player_state.health == player.Dead
}

pub fn receive_message_damage_from_a_stale_room_is_ignored_test() -> Nil {
  let state = in_game_state()
  assert session.receive_message(
      state,
      session.RoomMessage(room.new_id("stale room"), event.NpcHitYou("x", 1)),
    )
    |> effects
    == []
}

pub fn receive_message_npc_only_event_is_ignored_test() -> Nil {
  let state = in_game_state()
  let assert session.InGame(player_state, _) = state.status
  assert session.receive_message(
      state,
      session.RoomMessage(player_state.room.id, event.NpcTargetGone),
    )
    |> effects
    == []
}

// ----- World replies ----------------------------------------------------

pub fn join_reply_starts_the_game_test() -> Nil {
  let state = joining_state()
  let entrance = room_info("entrance")

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Joined(Ok(entrance))),
    )

  assert effects == [session.EnterRoom(entrance, 0)]
  let assert session.InGame(player.State(_pid, name, room, _health), _) =
    new_state.status
  assert name == "Alice"
  assert room == entrance
}

pub fn join_reply_when_already_in_game_is_ignored_test() -> Nil {
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

pub fn join_error_returns_to_awaiting_name_test() -> Nil {
  let state = joining_state()

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(
        world.Joined(Error(world.NoSuchRoom(state.entrance))),
      ),
    )

  assert effects
    == [session.Do(player.Output("The room entrance does not exist."))]
  assert new_state.status == session.AwaitingName
}

pub fn join_name_taken_test() -> Nil {
  let state = joining_state()

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Joined(Error(world.AlreadyLoggedIn("Alice")))),
    )

  assert effects
    == [
      session.Do(player.Output(
        "The name Alice is already in use. Choose another name: ",
      )),
    ]
  assert new_state.status == session.AwaitingName
}

pub fn join_error_when_already_in_game_is_ignored_test() -> Nil {
  let state = in_room_state(room_info("entrance"))

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(
        world.Joined(Error(world.NoSuchRoom(state.entrance))),
      ),
    )

  // A late error must not demote a player who is already in the game, or the
  // room keeps an occupant that no session knows about.
  assert effects == []
  assert new_state.status == state.status
}

pub fn move_reply_relocates_the_player_test() -> Nil {
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
  let assert session.InGame(player.State(_pid, name, room, _health), _) =
    new_state.status
  assert name == "Alice"
  assert room == corridor
}

pub fn move_reply_from_a_stale_room_is_ignored_test() -> Nil {
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

pub fn move_error_test() -> Nil {
  let entrance = room_info("entrance")
  let state = in_room_state(entrance)

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Moved(
        entrance.id,
        Error(world.NonExistingExit(
          from: entrance.id,
          direction: direction.North,
        )),
      )),
    )

  assert effects == [session.Do(player.Output("You can't go that way."))]
  assert new_state.status == state.status
}

pub fn move_error_from_a_stale_room_is_ignored_test() -> Nil {
  let entrance = room_info("entrance")
  let corridor = room_info("corridor")
  let state = in_room_state(corridor)

  let #(new_state, effects) =
    session.receive_message(
      state,
      session.WorldMessage(world.Moved(
        entrance.id,
        Error(world.NonExistingExit(
          from: entrance.id,
          direction: direction.North,
        )),
      )),
    )

  assert effects == []
  assert new_state.status == state.status
}

pub fn join_timeout_returns_to_awaiting_name_test() -> Nil {
  let state = joining_state()

  let #(new_state, effects) =
    session.receive_message(state, session.JoinTimeout)

  assert effects
    == [session.Do(player.Output("The world is not answering, try again: "))]
  assert new_state.status == session.AwaitingName
}

pub fn join_timeout_while_in_game_is_ignored_test() -> Nil {
  let state = in_room_state(room_info("entrance"))
  assert session.receive_message(state, session.JoinTimeout) |> effects == []
}

// Two moves in one packet are both dispatched from the room the player was in,
// so the second reply is stale and must not move them a second time.
pub fn second_move_reply_in_the_same_packet_is_ignored_test() -> Nil {
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
  let assert session.InGame(player_state, _) = state.status
  session.State(
    ..state,
    status: session.InGame(
      player_state,
      room_watch: Some(session.RoomWatch(pid, process.monitor(pid))),
    ),
  )
}

pub fn room_down_reenters_the_current_room_test() -> Nil {
  let entrance = room_info("entrance")
  let me = process.self()
  let state = watched_state(entrance, me)

  let #(new_state, effects) =
    session.receive_message(state, session.RoomDown(Some(me)))

  assert effects == [session.EnterRoom(entrance, 0)]
  let assert session.InGame(_, room_watch) = new_state.status
  assert room_watch == None
}

pub fn room_down_from_a_room_we_have_left_is_ignored_test() -> Nil {
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

pub fn room_down_when_not_in_game_is_ignored_test() -> Nil {
  let state = joining_state()
  assert session.receive_message(state, session.RoomDown(Some(process.self())))
    |> effects
    == []
}

pub fn retry_enter_reemits_enter_room_test() -> Nil {
  let entrance = room_info("entrance")
  let state = in_room_state(entrance)

  let #(_, effects) =
    session.receive_message(state, session.RetryEnter(entrance, 1))

  assert effects == [session.EnterRoom(entrance, 1)]
}

pub fn retry_enter_gives_up_after_max_attempts_test() -> Nil {
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

pub fn retry_enter_when_not_in_game_is_ignored_test() -> Nil {
  let state = joining_state()
  assert session.receive_message(
      state,
      session.RetryEnter(room_info("entrance"), 1),
    )
    |> effects
    == []
}

// ----- Disconnecting ----------------------------------------------------

pub fn closed_test() -> Nil {
  let state = in_game_state()
  let assert session.InGame(player_state, _) = state.status
  assert session.closed(state)
    == [session.LeaveRoom(player_state.room.process_name)]
}

pub fn closed_in_awaiting_name_test() -> Nil {
  assert session.closed(awaiting_name_state()) == []
}

pub fn closed_in_joining_test() -> Nil {
  assert session.closed(joining_state()) == []
}

pub fn to_occupant_test() -> Nil {
  let state = in_game_state()
  let assert session.InGame(player_state, _) = state.status
  let occupant = session.to_occupant(state, player_state)
  assert occupant.pid == player_state.pid
  assert occupant.name == player_state.name
}
