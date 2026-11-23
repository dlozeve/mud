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

pub fn render_arrive_to_self_staircase_up_test() {
  assert player.render(
      event.YouAreIn("the dungeon", "It is dark.", [direction.Up]),
    )
    == "You are in the dungeon.\nIt is dark.\nThere is a staircase leading up."
}

pub fn render_arrive_to_self_staircases_up_and_down_test() {
  assert player.render(
      event.YouAreIn("the dungeon", "It is dark.", [
        direction.Up,
        direction.Down,
      ]),
    )
    == "You are in the dungeon.\nIt is dark.\nThere are staircases leading up and down."
}

pub fn render_arrive_to_self_door_and_staircase_test() {
  assert player.render(
      event.YouAreIn("the dungeon", "It is dark.", [
        direction.North,
        direction.Down,
      ]),
    )
    == "You are in the dungeon.\nIt is dark.\nThere is a single door, North.\nThere is a staircase leading down."
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
  player.new(process.self(), "Alice", room())
}

pub fn decide_event_renders_to_output_test() {
  let player_state = state()
  assert player.decide(
      player_state,
      event.OccupantSaid("Bob", "hi", event.Player),
    )
    == #(player_state, [player.Output("Bob says: hi")])
}

pub fn decide_command_say_test() {
  let player_state = state()
  assert player.decide_command(player_state, command.Say("hi"))
    == #(player_state, [player.Say("hi")])
}

pub fn decide_command_quit_test() {
  let player_state = state()
  assert player.decide_command(player_state, command.Quit)
    == #(player_state, [])
}

pub fn decide_command_bad_direction_test() {
  let player_state = state()
  assert player.decide_command(player_state, command.BadDirection("somewhere"))
    == #(player_state, [player.Output("Unknown direction: somewhere")])
}

pub fn decide_command_unknown_test() {
  let player_state = state()
  assert player.decide_command(player_state, command.Unknown("sing"))
    == #(player_state, [player.Output("Unknown command: sing")])
}

// ----- Combat -----------------------------------------------------------

pub fn render_occupant_died_test() {
  assert player.render(event.OccupantDied("Alice", event.Player))
    == "Alice has died."
}

pub fn render_npc_died_test() {
  assert player.render(event.OccupantDied("a goblin", event.Npc))
    == "A goblin has died."
}

pub fn render_attack_failed_test() {
  assert player.render(event.AttackFailed("goblin"))
    == "There is no goblin here."
}

pub fn render_hit_npc_test() {
  assert player.render(event.YouHitNpc("a goblin", 2))
    == "You hit a goblin for 2 damage."
}

pub fn render_miss_npc_test() {
  assert player.render(event.YouMissedNpc("a goblin")) == "You miss a goblin."
}

pub fn render_npc_hit_you_test() {
  assert player.render(event.NpcHitYou("a goblin", 1))
    == "A goblin hits you for 1 damage."
}

pub fn decide_command_attack_test() {
  let player_state = state()
  assert player.decide_command(player_state, command.Attack("a goblin"))
    == #(player_state, [player.Attack("a goblin")])
}

pub fn decide_command_missing_target_test() {
  let player_state = state()
  assert player.decide_command(player_state, command.MissingTarget)
    == #(player_state, [player.Output("Attack what?")])
}

pub fn decide_damage_reduces_hp_test() {
  let player_state = state()
  let #(updated_state, actions) =
    player.decide(player_state, event.NpcHitYou("a goblin", 10))
  assert updated_state.hp == 90
  assert actions
    == [
      player.Output("A goblin hits you for 10 damage."),
      player.Output("You have 90/100 hp."),
    ]
}

pub fn decide_lethal_damage_dies_test() {
  let player_state = state()
  let #(updated_state, actions) =
    player.decide(player_state, event.NpcHitYou("a goblin", 100))
  assert updated_state.hp == 0
  assert actions == [player.Output("You died"), player.Die]
}

pub fn decide_damage_never_goes_negative_test() {
  let player_state = state()
  let #(updated_state, _actions) =
    player.decide(player_state, event.NpcHitYou("a goblin", 500))
  assert updated_state.hp == 0
}

pub fn decide_npc_only_combat_events_are_ignored_test() {
  let player_state = state()
  assert player.decide(player_state, event.NpcTargetGone) == #(player_state, [])
  assert player.decide(
      player_state,
      event.NpcAttacked("Alice", process.self(), 2),
    )
    == #(player_state, [])
}
