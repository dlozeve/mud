import gleam/erlang/process
import mud/command
import mud/direction
import mud/event
import mud/id
import mud/player

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

fn state() -> player.State {
  player.State(id.new_player_id("alice"), "Alice", process.new_subject())
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
