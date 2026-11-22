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
  assert player.render(event.OccupantArrived("Alice", event.Player))
    == "Alice arrives."
}

pub fn render_npc_arrive_to_other_test() {
  assert player.render(event.OccupantArrived("a goblin", event.Npc))
    == "A goblin has entered the room."
}

pub fn render_leave_to_other_test() {
  assert player.render(event.OccupantLeft("Alice", event.Player))
    == "Alice leaves."
}

pub fn render_npc_leave_to_other_test() {
  assert player.render(event.OccupantLeft("a goblin", event.Npc))
    == "A goblin has left the room."
}

pub fn render_say_to_self_test() {
  assert player.render(event.YouSaid("hi")) == "You say: hi"
}

pub fn render_say_to_other_test() {
  assert player.render(event.OccupantSaid("Alice", "hi", event.Player))
    == "Alice says: hi"
}

pub fn render_occupant_list_test() {
  assert player.render(event.OccupantList(["Alice", "Bob"], []))
    == "Alice and Bob are here."
}

pub fn render_occupant_list_single_test() {
  assert player.render(event.OccupantList(["Alice"], [])) == "Alice is here."
}

pub fn render_occupant_list_alone_test() {
  assert player.render(event.OccupantList([], [])) == "You are alone here."
}

pub fn render_npc_say_to_other_test() {
  assert player.render(event.OccupantSaid("a goblin", "grrr", event.Npc))
    == "A goblin says: grrr"
}

pub fn render_occupant_list_npc_only_test() {
  assert player.render(event.OccupantList([], ["a goblin"]))
    == "There is a goblin in the room."
}

pub fn render_occupant_list_npc_plural_test() {
  assert player.render(event.OccupantList([], ["a goblin", "a bat"]))
    == "There are a goblin and a bat in the room."
}

pub fn render_occupant_list_players_and_npcs_test() {
  assert player.render(event.OccupantList(["Alice"], ["a goblin"]))
    == "Alice is here.\nThere is a goblin in the room."
}

pub fn render_occupant_list_players_plural_and_npcs_test() {
  assert player.render(event.OccupantList(["Alice", "Bob"], ["a goblin"]))
    == "Alice and Bob are here.\nThere is a goblin in the room."
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
  assert player.decide(s, event.OccupantSaid("Bob", "hi", event.Player))
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
