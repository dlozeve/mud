import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor
import mud/map_loader
import mud/server
import mud/tree
import simplifile

pub fn main() -> Nil {
  let map_path = "./maps/map.toml"
  let assert Ok(input) = simplifile.read(map_path)
  let assert Ok(map_loader.Map(rooms:, entrance:)) =
    map_loader.parse_rooms(input)
  let world_name = process.new_name("world")

  let supervisor =
    tree.rooms_supervisor(rooms)
    |> static_supervisor.add(tree.world_child(world_name, rooms))
    |> static_supervisor.add(server.server_child(world_name, entrance, 3000))
    |> static_supervisor.start

  case supervisor {
    Ok(_) -> process.sleep_forever()
    Error(actor.InitTimeout) -> io.println_error("Timeout error")
    Error(actor.InitFailed(s)) ->
      io.println_error("Error during startup: " <> s)
    Error(actor.InitExited(_)) -> io.println_error("Init exited")
  }
}
