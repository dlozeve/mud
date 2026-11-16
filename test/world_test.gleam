import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import mud/direction.{type Direction}
import mud/id.{type RoomId}
import mud/room
import mud/world

fn room_with(
  id: RoomId,
  name: String,
  exits: Dict(Direction, RoomId),
) -> room.Def {
  room.Def(
    process_name: process.new_name(name),
    id: id,
    name: name,
    description: name <> " description",
    exits: exits,
  )
}

fn rooms() {
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let entrance =
    room_with(r1, "entrance", dict.from_list([#(direction.North, r2)]))
  let corridor =
    room_with(r2, "corridor", dict.from_list([#(direction.South, r1)]))
  [entrance, corridor]
}

fn state_with(rooms: List(room.Def)) -> world.State {
  world.State(
    rooms: dict.from_list(list.map(rooms, fn(r) { #(r.id, r) })),
    players: dict.new(),
  )
}

// ----- Join -------------------------------------------------------------

pub fn join_replies_with_the_room_test() {
  let r1 = id.new_room_id("r1")
  let entrance = room_with(r1, "entrance", dict.new())
  let state = state_with([entrance])
  let reply_to = process.new_subject()
  let player_id = id.new_player_id("alice")

  let #(new_state, actions) =
    world.decide(
      state,
      world.Join(
        player: player_id,
        pid: process.self(),
        at: r1,
        reply_to: reply_to,
      ),
    )

  assert actions
    == [
      world.JoinReply(
        player: player_id,
        reply_to: reply_to,
        result: world.Joined(Ok(entrance)),
      ),
      world.Monitor(process.self()),
    ]
  assert new_state.rooms == state.rooms
  assert new_state.players == dict.from_list([#(player_id, process.self())])
}

pub fn join_unknown_room_test() {
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")
  let entrance = room_with(r1, "entrance", dict.new())
  let state = state_with([entrance])
  let reply_to = process.new_subject()
  let player_id = id.new_player_id("alice")

  let #(new_state, actions) =
    world.decide(
      state,
      world.Join(
        player: player_id,
        pid: process.self(),
        at: r2,
        reply_to: reply_to,
      ),
    )

  assert actions
    == [
      world.JoinReply(
        player: player_id,
        reply_to: reply_to,
        result: world.Joined(Error(world.NoSuchRoom)),
      ),
    ]
  assert new_state == state
}

pub fn join_while_already_logged_in_test() {
  let r1 = id.new_room_id("r1")
  let entrance = room_with(r1, "entrance", dict.new())
  let player_id = id.new_player_id("alice")
  let other_pid = process.spawn(fn() { Nil })
  let state =
    world.State(
      rooms: dict.from_list([#(r1, entrance)]),
      players: dict.from_list([#(player_id, other_pid)]),
    )
  let reply_to = process.new_subject()

  let #(new_state, actions) =
    world.decide(
      state,
      world.Join(
        player: player_id,
        pid: process.self(),
        at: r1,
        reply_to: reply_to,
      ),
    )

  assert actions
    == [
      world.JoinReply(
        player: player_id,
        reply_to: reply_to,
        result: world.Joined(Error(world.AlreadyLoggedIn)),
      ),
    ]
  // The existing session keeps the name.
  assert new_state.players == dict.from_list([#(player_id, other_pid)])
}

// ----- Eviction ---------------------------------------------------------

pub fn down_frees_the_name_test() {
  let r1 = id.new_room_id("r1")
  let entrance = room_with(r1, "entrance", dict.new())
  let player_id = id.new_player_id("alice")
  let dead_pid = process.spawn(fn() { Nil })
  let state =
    world.State(
      rooms: dict.from_list([#(r1, entrance)]),
      players: dict.from_list([#(player_id, dead_pid)]),
    )

  let #(new_state, actions) = world.decide(state, world.Down(Some(dead_pid)))

  assert actions == []
  assert new_state.players == dict.new()
}

pub fn down_of_an_unknown_process_is_ignored_test() {
  let r1 = id.new_room_id("r1")
  let entrance = room_with(r1, "entrance", dict.new())
  let player_id = id.new_player_id("alice")
  let state =
    world.State(
      rooms: dict.from_list([#(r1, entrance)]),
      players: dict.from_list([#(player_id, process.self())]),
    )

  let #(new_state, _actions) =
    world.decide(state, world.Down(Some(process.spawn(fn() { Nil }))))

  assert new_state == state
}

pub fn down_of_none_is_ignored_test() {
  let r1 = id.new_room_id("r1")
  let entrance = room_with(r1, "entrance", dict.new())
  let player_id = id.new_player_id("alice")
  let state =
    world.State(
      rooms: dict.from_list([#(r1, entrance)]),
      players: dict.from_list([#(player_id, process.self())]),
    )

  let #(new_state, _actions) = world.decide(state, world.Down(None))

  assert new_state == state
}

// ----- Move -------------------------------------------------------------

pub fn move_replies_with_the_destination_room_test() {
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor])
  let reply_to = process.new_subject()

  let #(new_state, actions) =
    world.decide(
      state,
      world.Move(from: entrance.id, dir: direction.North, reply_to: reply_to),
    )

  assert actions
    == [world.MoveReply(reply_to, world.Moved(entrance.id, Ok(corridor)))]
  assert new_state == state
}

pub fn move_without_an_exit_test() {
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor])
  let reply_to = process.new_subject()

  let #(new_state, actions) =
    world.decide(
      state,
      world.Move(from: entrance.id, dir: direction.West, reply_to: reply_to),
    )

  assert actions
    == [
      world.MoveReply(
        reply_to,
        world.Moved(entrance.id, Error(world.NonExistingExit)),
      ),
    ]
  assert new_state == state
}

pub fn move_into_a_missing_room_test() {
  // The entrance has an exit north, but the corridor is not in the map.
  let assert [entrance, _corridor] = rooms()
  let state = state_with([entrance])
  let reply_to = process.new_subject()

  let #(new_state, actions) =
    world.decide(
      state,
      world.Move(from: entrance.id, dir: direction.North, reply_to: reply_to),
    )

  assert actions
    == [
      world.MoveReply(
        reply_to,
        world.Moved(entrance.id, Error(world.NonExistingRoom)),
      ),
    ]
  assert new_state == state
}

pub fn move_from_an_unknown_room_test() {
  let assert [_entrance, corridor] = rooms()
  let state = state_with([corridor])
  let reply_to = process.new_subject()

  let #(new_state, actions) =
    world.decide(
      state,
      world.Move(
        from: id.new_room_id("nowhere"),
        dir: direction.North,
        reply_to: reply_to,
      ),
    )

  assert actions
    == [
      world.MoveReply(
        reply_to,
        world.Moved(id.new_room_id("nowhere"), Error(world.NonExistingRoom)),
      ),
    ]
  assert new_state == state
}

// ----- Guarded sends ----------------------------------------------------

// The world may be restarting, so the send must be dropped rather than
// panicking on an unregistered name.
pub fn sending_to_an_unregistered_world_is_dropped_test() {
  let world_name = process.new_name("no such world")
  let replies = process.new_subject()

  world.join(
    world_name,
    id.new_player_id("alice"),
    process.self(),
    id.new_room_id("r1"),
    replies,
  )
  world.move(world_name, id.new_room_id("r1"), direction.North, replies)
}
