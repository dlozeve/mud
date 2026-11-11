import mud/event
import mud/player

pub fn render_arrive_to_self_test() {
  assert player.render(event.YouArrived("the dungeon", "It is dark."))
    == "You enter the dungeon.\nIt is dark."
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
