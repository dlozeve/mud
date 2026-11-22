import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import mud/direction.{type Direction}
import mud/room
import tom

pub type Map {
  Map(rooms: List(room.Def), entrance: room.Def)
}

pub type ParseError {
  TomlError(tom.ParseError)
  DecoderError(List(decode.DecodeError))
  InvalidExits(List(#(room.Id, Direction)))
  InvalidEntrance(String)
}

pub fn parse_rooms(input: String) -> Result(Map, ParseError) {
  use parsed <- result.try(
    tom.parse_to_dynamic(input) |> result.map_error(TomlError),
  )
  use map_src <- result.try(
    decode.run(parsed, map_src_decoder()) |> result.map_error(DecoderError),
  )
  let rooms = list.map(map_src.rooms, room_def)
  let rooms_dict = dict.from_list(list.map(rooms, fn(r) { #(r.id, r) }))
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
  case rooms, dict.get(rooms_dict, room.new_id(map_src.entrance)) {
    Ok(rooms), Ok(entrance) -> Ok(Map(rooms:, entrance:))
    Error(e), _ -> Error(e)
    _, Error(_) -> Error(InvalidEntrance(map_src.entrance))
  }
}

type RoomSrc {
  RoomSrc(
    id: String,
    name: String,
    description: String,
    exits: Dict(Direction, String),
  )
}

type MapSrc {
  MapSrc(entrance: String, rooms: List(RoomSrc))
}

fn direction_decoder() -> decode.Decoder(Direction) {
  use variant <- decode.then(decode.string)
  case string.lowercase(variant) {
    "north" -> decode.success(direction.North)
    "east" -> decode.success(direction.East)
    "south" -> decode.success(direction.South)
    "west" -> decode.success(direction.West)
    _ -> decode.failure(direction.North, "Direction")
  }
}

fn room_src_decoder() -> decode.Decoder(RoomSrc) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use description <- decode.field("description", decode.string)
  use exits <- decode.field(
    "exits",
    decode.dict(direction_decoder(), decode.string),
  )
  decode.success(RoomSrc(id:, name:, description:, exits:))
}

fn map_src_decoder() -> decode.Decoder(MapSrc) {
  use entrance <- decode.field("entrance", decode.string)
  use rooms <- decode.field("rooms", decode.list(room_src_decoder()))
  decode.success(MapSrc(entrance:, rooms:))
}

fn room_def(room: RoomSrc) -> room.Def {
  room.Def(
    process_name: process.new_name(room.id),
    id: room.new_id(room.id),
    name: room.name,
    description: room.description,
    exits: dict.map_values(room.exits, fn(_dir, id) { room.new_id(id) }),
  )
}

fn reverse_direction(dir: Direction) -> Direction {
  case dir {
    direction.North -> direction.South
    direction.East -> direction.West
    direction.South -> direction.North
    direction.West -> direction.East
  }
}

fn validate_exits(
  rooms_dict: Dict(room.Id, room.Def),
  room: room.Def,
) -> Result(room.Def, ParseError) {
  let dir_results =
    dict.map_values(room.exits, fn(dir, id) {
      case dict.get(rooms_dict, id) {
        Ok(target_room) ->
          case dict.get(target_room.exits, reverse_direction(dir)) {
            Ok(rid) if rid == room.id -> Ok(room)
            _ -> Error(#(room.id, dir))
          }
        Error(_) -> Error(#(room.id, dir))
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
