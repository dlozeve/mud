import gleam/dict
import gleam/erlang/process
import mud/command
import mud/direction
import mud/event
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

pub fn render_occupant_list_test() {
  assert player.render(event.OccupantList(["Alice", "Bob"]))
    == "Alice and Bob are here."
}

pub fn render_occupant_list_single_test() {
  assert player.render(event.OccupantList(["Alice"])) == "Alice is here."
}

pub fn render_occupant_list_alone_test() {
  assert player.render(event.OccupantList([])) == "You are alone here."
}

fn room() -> room.Def {
  room.Def(
    process_name: process.new_name("room"),
    id: room.new_id("room"),
    name: "a room",
    description: "A room.",
    exits: dict.new(),
  )
}

fn state() -> player.State {
  player.State(pid: process.self(), name: "Alice", room: room())
}

pub fn decide_event_renders_to_output_test() {
  let s = state()
  assert player.decide(s, event.PlayerSaid("Bob", "hi"))
    == #(s, [player.Output("Bob says: hi")])
}

pub fn decide_command_say_test() {
  let s = state()
  assert player.decide_command(s, command.Say("hi")) == #(s, [player.Say("hi")])
}

pub fn decide_command_quit_test() {
  let s = state()
  assert player.decide_command(s, command.Quit) == #(s, [])
}

pub fn decide_command_bad_direction_test() {
  let s = state()
  assert player.decide_command(s, command.BadDirection("somewhere"))
    == #(s, [player.Output("Unknown direction: somewhere")])
}

pub fn decide_command_unknown_test() {
  let s = state()
  assert player.decide_command(s, command.Unknown("sing"))
    == #(s, [player.Output("Unknown command: sing")])
}
