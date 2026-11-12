import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/result
import mud/event
import mud/id.{type RoomId}
import mud/world

fn session_with(name: String) -> event.Session {
  event.Session(id.new_player_id(name), name, event.Listener(fn(_) { Nil }))
}

fn room_with(id: RoomId, name: String) -> world.RoomInfo {
  world.RoomInfo(process.new_subject(), id, name, name <> " description")
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
  let entrance = room_with(r1, "entrance")
  let state = state_with([entrance], [])

  let #(new_state, actions) = world.decide(state, world.Join(alice, r1))

  assert actions
    == [
      world.TellYouArrived(alice, entrance.name, entrance.description),
      world.EnterRoom(alice, entrance.subject),
    ]
  assert dict.get(new_state.members, alice.id) == Ok(world.Member(alice, r1))
}

pub fn join_existing_member_emits_nothing_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let entrance = room_with(r1, "entrance")
  let state = state_with([entrance], [#(alice, r1)])

  let #(new_state, actions) = world.decide(state, world.Join(alice, r1))

  assert actions == []
  assert dict.get(new_state.members, alice.id) == Ok(world.Member(alice, r1))
}

pub fn join_unknown_room_emits_nothing_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")
  let entrance = room_with(r1, "entrance")
  let state = state_with([entrance], [])

  let #(new_state, actions) = world.decide(state, world.Join(alice, r2))

  assert actions == []
  assert result.is_error(dict.get(new_state.members, alice.id))
}

pub fn move_emits_leave_then_arrive_then_enter_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let entrance = room_with(r1, "entrance")
  let corridor = room_with(r2, "corridor")
  let state = state_with([entrance, corridor], [#(alice, r1)])

  let #(new_state, actions) = world.decide(state, world.Move(alice.id, r2))

  assert actions
    == [
      world.LeaveRoom(alice.id, entrance.subject),
      world.TellYouArrived(alice, corridor.name, corridor.description),
      world.EnterRoom(alice, corridor.subject),
    ]
  assert dict.get(new_state.members, alice.id) == Ok(world.Member(alice, r2))
}

pub fn move_to_the_same_room_emits_nothing_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let entrance = room_with(r1, "entrance")
  let corridor = room_with(r2, "corridor")
  let state = state_with([entrance, corridor], [#(alice, r1)])

  let #(new_state, actions) = world.decide(state, world.Move(alice.id, r1))

  assert actions == []
  assert dict.get(new_state.members, alice.id) == Ok(world.Member(alice, r1))
}

pub fn move_to_an_unknown_room_emits_nothing_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let entrance = room_with(r1, "entrance")
  let state = state_with([entrance], [#(alice, r1)])

  let #(new_state, actions) = world.decide(state, world.Move(alice.id, r2))

  assert actions == []
  assert dict.get(new_state.members, alice.id) == Ok(world.Member(alice, r1))
}

pub fn move_from_an_unknown_room_emits_only_entrance_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let corridor = room_with(r2, "corridor")
  let state = state_with([corridor], [#(alice, r1)])

  let #(new_state, actions) = world.decide(state, world.Move(alice.id, r2))

  assert actions
    == [
      world.TellYouArrived(alice, corridor.name, corridor.description),
      world.EnterRoom(alice, corridor.subject),
    ]
  assert dict.get(new_state.members, alice.id) == Ok(world.Member(alice, r2))
}

pub fn move_from_unknown_player_emits_nothing_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let entrance = room_with(r1, "entrance")
  let corridor = room_with(r2, "corridor")
  let state = state_with([entrance, corridor], [])

  let #(new_state, actions) = world.decide(state, world.Move(alice.id, r2))

  assert actions == []
  assert result.is_error(dict.get(new_state.members, alice.id))
}

pub fn leave_member_removed_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let entrance = room_with(r1, "entrance")
  let corridor = room_with(r2, "corridor")
  let state = state_with([entrance, corridor], [#(alice, r1)])

  let #(new_state, actions) = world.decide(state, world.Leave(alice.id))

  assert actions == [world.LeaveRoom(alice.id, entrance.subject)]
  assert result.is_error(dict.get(new_state.members, alice.id))
}

pub fn leave_unknown_room_member_removed_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let corridor = room_with(r2, "corridor")
  let state = state_with([corridor], [#(alice, r1)])

  let #(new_state, actions) = world.decide(state, world.Leave(alice.id))

  assert actions == []
  assert result.is_error(dict.get(new_state.members, alice.id))
}

pub fn player_says_emits_say_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let entrance = room_with(r1, "entrance")
  let corridor = room_with(r2, "corridor")
  let state = state_with([entrance, corridor], [#(alice, r1)])

  let #(_, actions) = world.decide(state, world.PlayerSays(alice.id, "hi"))

  assert actions == [world.Say(alice.id, entrance.subject, "hi")]
}

pub fn player_says_from_unknown_member_emits_nothing_test() {
  let alice = session_with("alice")
  let r1 = id.new_room_id("r1")
  let r2 = id.new_room_id("r2")

  let entrance = room_with(r1, "entrance")
  let corridor = room_with(r2, "corridor")
  let state = state_with([entrance, corridor], [])

  let #(_, actions) = world.decide(state, world.PlayerSays(alice.id, "hi"))

  assert actions == []
}
