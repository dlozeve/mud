import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
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
  world.State(rooms: dict.from_list(list.map(rooms, fn(r) { #(r.id, r) })))
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
      world.Join(player: player_id, at: r1, reply_to: reply_to),
    )

  assert actions
    == [
      world.JoinReply(
        player: player_id,
        reply_to: reply_to,
        result: world.Joined(Ok(entrance)),
      ),
    ]
  assert new_state == state
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
      world.Join(player: player_id, at: r2, reply_to: reply_to),
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

  assert actions == [world.MoveReply(reply_to, world.Moved(Ok(corridor)))]
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
    == [world.MoveReply(reply_to, world.Moved(Error(world.NonExistingExit)))]
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
    == [world.MoveReply(reply_to, world.Moved(Error(world.NonExistingRoom)))]
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
    == [world.MoveReply(reply_to, world.Moved(Error(world.NonExistingRoom)))]
  assert new_state == state
}
