import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
import mud/map_loader
import mud/server
import mud/tree
import simplifile
import woof

pub fn main() -> Nil {
  woof.dev()

  let map_path = "./maps/map.toml"
  let assert Ok(input) = simplifile.read(map_path)
  let assert Ok(map_loader.Map(rooms:, entrance:, npcs:)) =
    map_loader.parse_rooms(input)
  woof.info("map loaded", [
    woof.int("room_count", list.length(rooms)),
    woof.int("npc_count", list.length(npcs)),
    woof.str("map_path", map_path),
  ])
  let world_name = process.new_name("world")

  let #(server_child, listener) =
    server.server_child_with_listener(world_name, entrance.id, 3000)
  let supervisor =
    tree.rooms_supervisor(rooms)
    |> static_supervisor.add(tree.world_child(world_name, rooms))
    |> tree.add_npc_children(npcs)
    |> static_supervisor.add(server_child)
    |> static_supervisor.start

  case supervisor {
    Ok(_) -> {
      woof.info("server listening", [
        woof.int("port", server.listener_port(listener, 1000)),
      ])
      process.sleep_forever()
    }
    Error(actor.InitTimeout) ->
      woof.error_with("supervisor failed to start", "timeout", [])
    Error(actor.InitFailed(s)) ->
      woof.error_with("supervisor failed to start", s, [])
    Error(actor.InitExited(_)) -> woof.error("supervisor init exited", [])
  }
}
