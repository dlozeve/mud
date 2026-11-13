import mud/command
import mud/direction

pub fn parse_look_test() {
  assert command.parse("look for stuff") == command.Look
}

pub fn parse_look_uppercase_test() {
  assert command.parse("LOOK") == command.Look
}

pub fn say_something_test() {
  assert command.parse("say Hi THERE") == command.Say("Hi THERE")
}

pub fn say_nothing_test() {
  assert command.parse("say ") == command.Say("")
}

pub fn empty_test() {
  assert command.parse("") == command.Unknown("")
}

pub fn whitespace_only_test() {
  assert command.parse("   \t  \n  ") == command.Unknown("   \t  \n  ")
}

pub fn unknown_test() {
  assert command.parse("sing") == command.Unknown("sing")
}

pub fn go_test() {
  assert command.parse("go East") == command.Go(direction.East)
}

pub fn go_unknown_direction_test() {
  assert command.parse("go somewhere")
    == command.Unknown("Unknown direction: somewhere")
}

pub fn go_no_direction_test() {
  assert command.parse("go ") == command.Unknown("go ")
}
