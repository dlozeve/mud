//// Combat tuning and the pure hit rolls.
////
//// Actors call `roll` at their boundary and pass the result into their pure
//// `decide` function, so combat stays deterministic and testable.

import gleam/int

/// Players are deliberately much tougher than NPCs: a fight should be easy.
pub const player_max_hp = 100

/// The starting hp of an NPC whose map entry omits `hp`.
pub const npc_default_hp = 5

/// A player almost always lands a hit.
pub const player_hit_chance = 85

/// An NPC hits less often than a player.
pub const npc_hit_chance = 30

pub const player_damage = 2

pub const npc_damage = 1

/// The outcome of a hit roll.
pub type AttackOutcome {
  Hit
  Miss
}

/// A roll is an integer in the range 0-99.
pub fn roll() -> Int {
  int.random(100)
}

pub fn player_hits(roll: Int) -> AttackOutcome {
  case roll < player_hit_chance {
    True -> Hit
    False -> Miss
  }
}

pub fn npc_hits(roll: Int) -> AttackOutcome {
  case roll < npc_hit_chance {
    True -> Hit
    False -> Miss
  }
}

/// Render an outcome for a log field.
pub fn outcome_to_string(outcome: AttackOutcome) -> String {
  case outcome {
    Hit -> "hit"
    Miss -> "miss"
  }
}
