import mud/command
import mud/direction

pub fn parse_look_test() -> Nil {
  assert command.parse("look for stuff") == command.Look
}

pub fn parse_look_uppercase_test() -> Nil {
  assert command.parse("LOOK") == command.Look
}

pub fn say_something_test() -> Nil {
  assert command.parse("say Hi THERE") == command.Say("Hi THERE")
}

pub fn say_nothing_test() -> Nil {
  assert command.parse("say ") == command.Say("")
}

pub fn empty_test() -> Nil {
  assert command.parse("") == command.Unknown("")
}

pub fn whitespace_only_test() -> Nil {
  assert command.parse("   \t  \n  ") == command.Unknown("")
}

pub fn unknown_test() -> Nil {
  assert command.parse("sing") == command.Unknown("sing")
}

pub fn go_test() -> Nil {
  assert command.parse("go East") == command.Go(direction.East)
}

pub fn go_unknown_direction_test() -> Nil {
  assert command.parse("go somewhere") == command.BadDirection("somewhere")
}

pub fn go_no_direction_test() -> Nil {
  assert command.parse("go ") == command.MissingDirection
}

pub fn split_whitespace_test() -> Nil {
  assert command.parse("Go\t\r   \n NORTH \r\n") == command.Go(direction.North)
}

pub fn who_test() -> Nil {
  assert command.parse("Who is here?") == command.WhoIsHere
}

pub fn attack_test() -> Nil {
  assert command.parse("attack a goblin") == command.Attack("a goblin")
}

pub fn attack_is_case_insensitive_test() -> Nil {
  assert command.parse("ATTACK Goblin") == command.Attack("Goblin")
}

pub fn attack_missing_target_test() -> Nil {
  assert command.parse("attack") == command.MissingTarget
}
