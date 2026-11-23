import gleam/dict
import gleam/list
import mud/combat
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

  let assert Ok(map_loader.Map(rooms:, entrance:, npcs:)) =
    map_loader.parse_rooms(input)
  assert list.length(rooms) == 2
  // The npcs table is optional.
  assert npcs == []

  assert Ok(entrance)
    == list.find(rooms, fn(room_definition) {
      room_definition.id == room.new_id("entrance")
    })
  let assert Ok(corridor) =
    list.find(rooms, fn(room_definition) {
      room_definition.id == room.new_id("corridor")
    })

  assert entrance.name == "the dungeon entrance"
  assert entrance.description
    == "The bottom of an enormous stone staircase. Dark and ominous. Slow rumble coming from below."
  assert entrance.exits == dict.from_list([#(direction.North, corridor.id)])

  assert corridor.name == "a dimly-lit corridor"
  assert corridor.description
    == "Long and narrow, with a few torches on the walls. Damp."
  assert corridor.exits == dict.from_list([#(direction.South, entrance.id)])
}

pub fn parse_rooms_npcs_test() {
  let input =
    "entrance = \"entrance\"

[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"Dark.\"
[rooms.exits]
down = \"corridor\"


[[rooms]]
id = \"corridor\"
name = \"a dimly-lit corridor\"
description = \"Damp.\"
[rooms.exits]
up = \"entrance\"


[[npcs]]
id = \"goblin\"
name = \"a goblin\"
room = \"corridor\"
hp = 3


[[npcs]]
id = \"bat\"
name = \"a bat\"
room = \"entrance\"
"

  let assert Ok(map_loader.Map(rooms:, npcs:, ..)) =
    map_loader.parse_rooms(input)
  let assert Ok(corridor) =
    list.find(rooms, fn(room_definition) {
      room_definition.id == room.new_id("corridor")
    })
  let assert Ok(entrance) =
    list.find(rooms, fn(room_definition) {
      room_definition.id == room.new_id("entrance")
    })

  let assert Ok(goblin) =
    list.find(npcs, fn(npc_definition) { npc_definition.id == "goblin" })
  assert goblin.name == "a goblin"
  assert goblin.hp == 3
  // The room string is resolved to the loaded room definition.
  assert goblin.room == corridor

  let assert Ok(bat) =
    list.find(npcs, fn(npc_definition) { npc_definition.id == "bat" })
  assert bat.name == "a bat"
  // An omitted hp falls back to the combat default.
  assert bat.hp == combat.npc_default_hp
  assert bat.room == entrance
}

pub fn parse_rooms_npc_unknown_room_test() {
  let input =
    "entrance = \"entrance\"

[[rooms]]
id = \"entrance\"
name = \"the dungeon entrance\"
description = \"Dark.\"
[rooms.exits]
down = \"corridor\"


[[rooms]]
id = \"corridor\"
name = \"a dimly-lit corridor\"
description = \"Damp.\"
[rooms.exits]
up = \"entrance\"


[[npcs]]
id = \"goblin\"
name = \"a goblin\"
room = \"cellar\"
"

  let assert Error(error) = map_loader.parse_rooms(input)
  assert error == map_loader.InvalidNpcRoom(npc_id: "goblin", room: "cellar")
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
