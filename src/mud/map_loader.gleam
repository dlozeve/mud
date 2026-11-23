import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import mud/combat
import mud/direction.{type Direction}
import mud/npc
import mud/room
import tom

pub type Map {
  Map(rooms: List(room.Def), entrance: room.Def, npcs: List(npc.Def))
}

pub type ParseError {
  TomlError(tom.ParseError)
  DecoderError(List(decode.DecodeError))
  InvalidExits(List(#(room.Id, Direction)))
  InvalidEntrance(String)
  InvalidNpcRoom(npc_id: String, room: String)
}

pub fn parse_rooms(input: String) -> Result(Map, ParseError) {
  use parsed <- result.try(
    tom.parse_to_dynamic(input) |> result.map_error(TomlError),
  )
  use map_source <- result.try(
    decode.run(parsed, map_source_decoder()) |> result.map_error(DecoderError),
  )
  let rooms = list.map(map_source.rooms, room_def)
  let rooms_dict =
    dict.from_list(
      list.map(rooms, fn(room_definition) {
        #(room_definition.id, room_definition)
      }),
    )
  let rooms =
    list.fold(rooms, Ok([]), fn(acc, room) {
      case acc, validate_exits(rooms_dict, room) {
        Ok(rooms), Ok(room) -> Ok([room, ..rooms])
        Error(errs), Ok(_) -> Error(errs)
        Ok(_), Error(errs) -> Error(errs)
        Error(InvalidExits(errs1)), Error(InvalidExits(errs2)) ->
          Error(InvalidExits(list.append(errs1, errs2)))
        Error(e), Error(_) -> Error(e)
      }
    })
  let npcs =
    list.try_map(map_source.npcs, fn(npc_source) {
      case dict.get(rooms_dict, room.new_id(npc_source.room)) {
        Ok(room) ->
          Ok(npc.Def(
            id: npc_source.id,
            name: npc_source.name,
            room:,
            hp: npc_source.hp,
          ))
        Error(_) ->
          Error(InvalidNpcRoom(npc_id: npc_source.id, room: npc_source.room))
      }
    })
  case rooms, npcs, dict.get(rooms_dict, room.new_id(map_source.entrance)) {
    Ok(rooms), Ok(npcs), Ok(entrance) -> Ok(Map(rooms:, entrance:, npcs:))
    Error(e), _, _ -> Error(e)
    _, Error(e), _ -> Error(e)
    _, _, Error(_) -> Error(InvalidEntrance(map_source.entrance))
  }
}

type RoomSource {
  RoomSource(
    id: String,
    name: String,
    description: String,
    exits: Dict(Direction, String),
  )
}

type NpcSource {
  NpcSource(id: String, name: String, room: String, hp: Int)
}

type MapSource {
  MapSource(entrance: String, rooms: List(RoomSource), npcs: List(NpcSource))
}

fn direction_decoder() -> decode.Decoder(Direction) {
  use variant <- decode.then(decode.string)
  case string.lowercase(variant) {
    "north" -> decode.success(direction.North)
    "east" -> decode.success(direction.East)
    "south" -> decode.success(direction.South)
    "west" -> decode.success(direction.West)
    "up" -> decode.success(direction.Up)
    "down" -> decode.success(direction.Down)
    _ -> decode.failure(direction.North, "Direction")
  }
}

fn room_source_decoder() -> decode.Decoder(RoomSource) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use description <- decode.field("description", decode.string)
  use exits <- decode.field(
    "exits",
    decode.dict(direction_decoder(), decode.string),
  )
  decode.success(RoomSource(id:, name:, description:, exits:))
}

fn npc_source_decoder() -> decode.Decoder(NpcSource) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use room <- decode.field("room", decode.string)
  use hp <- decode.optional_field("hp", combat.npc_default_hp, decode.int)
  decode.success(NpcSource(id:, name:, room:, hp:))
}

fn map_source_decoder() -> decode.Decoder(MapSource) {
  use entrance <- decode.field("entrance", decode.string)
  use rooms <- decode.field("rooms", decode.list(room_source_decoder()))
  use npcs <- decode.optional_field(
    "npcs",
    [],
    decode.list(npc_source_decoder()),
  )
  decode.success(MapSource(entrance:, rooms:, npcs:))
}

fn room_def(room: RoomSource) -> room.Def {
  room.Def(
    process_name: process.new_name(room.id),
    id: room.new_id(room.id),
    name: room.name,
    description: room.description,
    exits: dict.map_values(room.exits, fn(_dir, id) { room.new_id(id) }),
  )
}

fn reverse_direction(direction: Direction) -> Direction {
  case direction {
    direction.North -> direction.South
    direction.East -> direction.West
    direction.South -> direction.North
    direction.West -> direction.East
    direction.Up -> direction.Down
    direction.Down -> direction.Up
  }
}

fn validate_exits(
  rooms_dict: Dict(room.Id, room.Def),
  room: room.Def,
) -> Result(room.Def, ParseError) {
  let dir_results =
    dict.map_values(room.exits, fn(exit_direction, id) {
      case dict.get(rooms_dict, id) {
        Ok(target_room) ->
          case dict.get(target_room.exits, reverse_direction(exit_direction)) {
            Ok(rid) if rid == room.id -> Ok(room)
            _ -> Error(#(room.id, exit_direction))
          }
        Error(_) -> Error(#(room.id, exit_direction))
      }
    })
  case
    dict.values(dir_results)
    |> result.partition
  {
    #(_, []) -> Ok(room)
    #(_, errors) -> Error(InvalidExits(errors))
  }
}
