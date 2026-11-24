import mud/combat

pub fn a_roll_below_the_player_chance_hits_test() -> Nil {
  assert combat.player_hits(0) == combat.Hit
  assert combat.player_hits(combat.player_hit_chance - 1) == combat.Hit
}

pub fn a_roll_at_the_player_chance_misses_test() -> Nil {
  assert combat.player_hits(combat.player_hit_chance) == combat.Miss
}

pub fn a_roll_below_the_npc_chance_hits_test() -> Nil {
  assert combat.npc_hits(0) == combat.Hit
  assert combat.npc_hits(combat.npc_hit_chance - 1) == combat.Hit
}

pub fn a_roll_at_the_npc_chance_misses_test() -> Nil {
  assert combat.npc_hits(combat.npc_hit_chance) == combat.Miss
}

pub fn npcs_hit_less_often_than_players_test() -> Nil {
  assert combat.npc_hit_chance < combat.player_hit_chance
}

pub fn npcs_are_much_weaker_than_players_test() -> Nil {
  assert combat.npc_default_hp * 10 < combat.player_max_hp
}

pub fn npc_damage_is_lower_than_player_damage_test() -> Nil {
  assert combat.npc_damage < combat.player_damage
}
