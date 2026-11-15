import gleam/dict
import gleam/erlang/process
import mud/command
import mud/direction
import mud/event
import mud/id
import mud/player
import mud/room

pub fn render_arrive_to_self_test() {
  assert player.render(
      event.YouAreIn("the dungeon", "It is dark.", [
        direction.North,
        direction.East,
        direction.West,
      ]),
    )
    == "You are in the dungeon.\nIt is dark.\nThere are 3 doors: North, East and West."
}

pub fn render_arrive_to_self_single_exit_test() {
  assert player.render(
      event.YouAreIn("the dungeon", "It is dark.", [direction.North]),
    )
    == "You are in the dungeon.\nIt is dark.\nThere is a single door, North."
}

pub fn render_arrive_to_self_no_exit_test() {
  assert player.render(event.YouAreIn("the dungeon", "It is dark.", []))
    == "You are in the dungeon.\nIt is dark.\nThere is no exit."
}

pub fn render_arrive_to_other_test() {
  assert player.render(event.PlayerArrived("Alice")) == "Alice arrives."
}

pub fn render_leave_to_other_test() {
  assert player.render(event.PlayerLeft("Alice")) == "Alice leaves."
}

pub fn render_say_to_self_test() {
  assert player.render(event.YouSaid("hi")) == "You say: hi"
}

pub fn render_say_to_other_test() {
  assert player.render(event.PlayerSaid("Alice", "hi")) == "Alice says: hi"
}

fn room() -> room.Def {
  room.Def(
    process_name: process.new_name("room"),
    id: id.new_room_id("room"),
    name: "a room",
    description: "A room.",
    exits: dict.new(),
  )
}

fn state() -> player.State {
  player.State(
    id: id.new_player_id("alice"),
    name: "Alice",
    world: process.new_subject(),
    room: room(),
  )
}

pub fn decide_event_renders_to_output_test() {
  let s = state()
  assert player.decide(s, player.Event(event.PlayerSaid("Bob", "hi")))
    == #(s, [player.Output("Bob says: hi")])
}

pub fn decide_command_say_test() {
  let s = state()
  assert player.decide_command(s, command.Say("hi")) == #(s, [player.Say("hi")])
}

pub fn decide_command_quit_test() {
  let s = state()
  assert player.decide_command(s, command.Quit) == #(s, [player.Leave])
}

pub fn decide_command_unknown_test() {
  let s = state()
  assert player.decide_command(s, command.Unknown("sing"))
    == #(s, [player.Unknown("sing")])
}

// The player carries the room it is in, so these are pure lookups.
pub fn decide_command_reports_its_own_room_test() {
  let s = state()
  assert s.room.name == "a room"
  assert s.room.id == id.new_room_id("room")
}

pub fn to_session_test() {
  let s = state()
  let session = player.to_session(process.new_subject(), s)
  assert session.id == s.id
  assert session.name == s.name
}
