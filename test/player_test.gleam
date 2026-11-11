import mud/event
import mud/player

pub fn render_say_to_self_test() {
  assert player.render(event.PlayerSaid("Alice", "hi"), "Alice")
    == "You say: hi"
}

pub fn render_say_to_other_test() {
  assert player.render(event.PlayerSaid("Alice", "hi"), "Bob")
    == "Alice says: hi"
}

pub fn render_enter_to_self_test() {
  assert player.render(event.PlayerEntered("Alice"), "Alice")
    == "You enter the room."
}

pub fn render_enter_to_other_test() {
  assert player.render(event.PlayerEntered("Alice"), "Bob")
    == "Alice enters the room."
}

pub fn render_leave_to_self_test() {
  assert player.render(event.PlayerLeft("Alice"), "Alice")
    == "You leave the room."
}

pub fn render_leave_to_other_test() {
  assert player.render(event.PlayerLeft("Alice"), "Bob")
    == "Alice leaves the room."
}

pub fn render_describe_test() {
  assert player.render(event.RoomDescribed("something"), "Bob") == "something"
}
