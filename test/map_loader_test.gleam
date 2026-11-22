import gleam/dict
import gleam/list
import mud/direction
import mud/map_loader
import mud/room

pub fn parse_rooms_test() {
  let input =
    "entrance = \"entrance\"

[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.\"
[rooms.exits]
north = \"corridor\"


[[rooms]]
id = \"corridor\"
name = \"a dimly-lit corridor\"
description = \"Long and narrow, with a few torches on the walls. Damp.\"
[rooms.exits]
south = \"entrance\"
"

  let assert Ok(map_loader.Map(rooms:, entrance:)) =
    map_loader.parse_rooms(input)
  assert list.length(rooms) == 2

  assert Ok(entrance)
    == list.find(rooms, fn(r) { r.id == room.new_id("entrance") })
  let assert Ok(corridor) =
    list.find(rooms, fn(r) { r.id == room.new_id("corridor") })

  assert entrance.name == "the dungeon entrance"
  assert entrance.description
    == "The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below."
  assert entrance.exits == dict.from_list([#(direction.North, corridor.id)])

  assert corridor.name == "a dimly-lit corridor"
  assert corridor.description
    == "Long and narrow, with a few torches on the walls. Damp."
  assert corridor.exits == dict.from_list([#(direction.South, entrance.id)])
}

pub fn parse_rooms_no_entrance_test() {
  let input =
    "[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.\"
[room.exits]

"
  let assert Error(map_loader.DecoderError(_)) = map_loader.parse_rooms(input)
}

pub fn parse_rooms_invalid_entrance_test() {
  let input =
    "entrance = \"somewhere\"

[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.\"
[rooms.exits]
north = \"corridor\"


[[rooms]]
id = \"corridor\"
name = \"a dimly-lit corridor\"
description = \"Long and narrow, with a few torches on the walls. Damp.\"
[rooms.exits]
south = \"entrance\"
"
  let assert Error(e) = map_loader.parse_rooms(input)
  assert e == map_loader.InvalidEntrance("somewhere")
}

pub fn parse_rooms_no_exits_test() {
  let input =
    "entrance = \"entrance\"

[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.\"
[room.exits]
north = \"corridor\"
"
  let assert Error(_) = map_loader.parse_rooms(input)
}

pub fn parse_rooms_no_exits_key_test() {
  let input =
    "entrance = \"entrance\"

[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.\"
"
  let assert Error(_) = map_loader.parse_rooms(input)
}

pub fn parse_rooms_invalid_exits_nonexisting_room_test() {
  let input =
    "entrance = \"entrance\"

[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.\"
[rooms.exits]
north = \"corridor\"
west = \"somewhere\"


[[rooms]]
id = \"corridor\"
name = \"a dimly-lit corridor\"
description = \"Long and narrow, with a few torches on the walls. Damp.\"
[rooms.exits]
south = \"entrance\""

  let assert Error(error) = map_loader.parse_rooms(input)
  assert error
    == map_loader.InvalidExits([#(room.new_id("entrance"), direction.West)])
}

pub fn parse_rooms_invalid_exits_no_corresponding_exit_test() {
  let input =
    "entrance = \"entrance\"

[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below.\"
[rooms.exits]
north = \"corridor\"


[[rooms]]
id = \"corridor\"
name = \"a dimly-lit corridor\"
description = \"Long and narrow, with a few torches on the walls. Damp.\"
[rooms.exits]
west = \"entrance\""

  let assert Error(error) = map_loader.parse_rooms(input)
  assert error
    == map_loader.InvalidExits([
      #(room.new_id("entrance"), direction.North),
      #(room.new_id("corridor"), direction.West),
    ])
}
