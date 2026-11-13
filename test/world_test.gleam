import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/result
import mud/direction.{type Direction}
import mud/event
import mud/id.{type RoomId}
import mud/world

fn session_with(name: String) -> event.Session {
  event.Session(id.new_player_id(name), name, event.Listener(fn(_) { Nil }))
}

fn room_with(
  id: RoomId,
  name: String,
  exits: Dict(Direction, RoomId),
) -> world.RoomInfo {
  world.RoomInfo(
    process.new_subject(),
    id:,
    name:,
    description: name <> " description",
    exits:,
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

fn state_with(
  rooms: List(world.RoomInfo),
  members: List(#(event.Session, RoomId)),
) -> world.State {
  world.State(
    rooms: dict.from_list(list.map(rooms, fn(r) { #(r.id, r) })),
    members: dict.from_list(
      list.map(members, fn(m) {
        let #(session, at) = m
        #(session.id, world.Member(session, at))
      }),
    ),
  )
}

pub fn join_emits_arrive_then_enter_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let entrance = room_with(r1, "entrance", dict.new())
  let state = state_with([entrance], [])

  let #(new_state, actions) = world.decide(state, world.Join(alice, r1))

  assert actions
    == [
      world.DescribeRoom(
        alice,
        entrance.name,
        entrance.description,
        dict.keys(entrance.exits),
      ),
      world.EnterRoom(alice, entrance.subject),
    ]
  assert dict.get(new_state.members, alice.id) == Ok(world.Member(alice, r1))
}

pub fn join_existing_member_emits_nothing_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let entrance = room_with(r1, "entrance", dict.new())
  let state = state_with([entrance], [#(alice, r1)])

  let #(new_state, actions) = world.decide(state, world.Join(alice, r1))

  assert actions == []
  assert dict.get(new_state.members, alice.id) == Ok(world.Member(alice, r1))
}

pub fn join_unknown_room_emits_nothing_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")
  let entrance = room_with(r1, "entrance", dict.new())
  let state = state_with([entrance], [])

  let #(new_state, actions) = world.decide(state, world.Join(alice, r2))

  assert actions == []
  assert result.is_error(dict.get(new_state.members, alice.id))
}

pub fn move_emits_leave_then_arrive_then_enter_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor], [#(alice, entrance.id)])

  let #(new_state, actions) =
    world.decide(state, world.Move(alice.id, direction.North))

  assert actions
    == [
      world.LeaveRoom(alice.id, entrance.subject),
      world.DescribeRoom(
        alice,
        corridor.name,
        corridor.description,
        dict.keys(corridor.exits),
      ),
      world.EnterRoom(alice, corridor.subject),
    ]
  assert dict.get(new_state.members, alice.id)
    == Ok(world.Member(alice, corridor.id))
}

pub fn move_to_an_empty_direction_emits_nothing_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor], [#(alice, entrance.id)])

  let #(new_state, actions) =
    world.decide(state, world.Move(alice.id, direction.West))

  assert actions == []
  assert dict.get(new_state.members, alice.id)
    == Ok(world.Member(alice, entrance.id))
}

pub fn move_to_a_nonexisting_room_emits_nothing_test() {
  let alice = session_with("alice")
  let assert [entrance, _] = rooms()
  let state = state_with([entrance], [#(alice, entrance.id)])

  let #(new_state, actions) =
    world.decide(state, world.Move(alice.id, direction.North))

  assert actions == []
  assert dict.get(new_state.members, alice.id)
    == Ok(world.Member(alice, entrance.id))
}

pub fn move_from_an_unknown_room_emits_nothing_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([corridor], [#(alice, entrance.id)])

  let #(new_state, actions) =
    world.decide(state, world.Move(alice.id, direction.North))

  assert actions == []
  assert dict.get(new_state.members, alice.id)
    == Ok(world.Member(alice, entrance.id))
}

pub fn move_from_unknown_player_emits_nothing_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor], [])

  let #(new_state, actions) =
    world.decide(state, world.Move(alice.id, direction.North))

  assert actions == []
  assert result.is_error(dict.get(new_state.members, alice.id))
}

pub fn leave_member_removed_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor], [#(alice, entrance.id)])

  let #(new_state, actions) = world.decide(state, world.Leave(alice.id))

  assert actions == [world.LeaveRoom(alice.id, entrance.subject)]
  assert result.is_error(dict.get(new_state.members, alice.id))
}

pub fn leave_unknown_room_member_removed_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([corridor], [#(alice, entrance.id)])

  let #(new_state, actions) = world.decide(state, world.Leave(alice.id))

  assert actions == []
  assert result.is_error(dict.get(new_state.members, alice.id))
}

pub fn player_says_emits_say_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor], [#(alice, entrance.id)])

  let #(_, actions) = world.decide(state, world.PlayerSays(alice.id, "hi"))

  assert actions == [world.Say(alice.id, entrance.subject, "hi")]
}

pub fn player_says_from_unknown_member_emits_nothing_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor], [])

  let #(_, actions) = world.decide(state, world.PlayerSays(alice.id, "hi"))

  assert actions == []
}

pub fn look_emits_reply_with_description_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor], [#(alice, entrance.id)])

  let #(_, actions) = world.decide(state, world.Look(alice.id))

  assert actions
    == [
      world.DescribeRoom(
        alice,
        entrance.name,
        entrance.description,
        dict.keys(entrance.exits),
      ),
    ]
}

pub fn look_in_wrong_room_emits_empty_reply_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance], [#(alice, corridor.id)])

  let #(_, actions) = world.decide(state, world.Look(alice.id))

  assert actions
    == [world.DescribeRoom(alice, "a nonexisting room", "An empty void.", [])]
}

pub fn look_non_existing_player_emits_empty_reply_test() {
  let alice = session_with("alice")
  let assert [entrance, corridor] = rooms()
  let state = state_with([entrance, corridor], [])

  let #(_, actions) = world.decide(state, world.Look(alice.id))

  assert actions == []
}
