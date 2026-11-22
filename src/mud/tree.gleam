import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import mud/npc
import mud/room
import mud/world

// The building blocks of the supervision tree, shared by the application and
// the integration tests, so that a test exercises the real actors.

pub fn room_child(
  def: room.Def,
) -> supervision.ChildSpecification(Subject(room.Message)) {
  let state = room.State(def:, occupants: dict.new())
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(_, pid, _) -> room.Down(Some(pid))
            // unreachable
            process.PortDown(..) -> room.Down(None)
          }
        })
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(room.handle_message)
    |> actor.named(def.process_name)
    |> actor.start
  })
}

pub fn npc_child(
  id: String,
  name: String,
  room: room.Def,
) -> supervision.ChildSpecification(Subject(npc.Message)) {
  supervision.worker(fn() {
    let result =
      actor.new_with_initialiser(1000, fn(subject) {
        // The NPC monitors its room, so it also selects for DOWN messages.
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> process.select_monitors(fn(down) {
            case down {
              process.ProcessDown(_, pid, _) -> npc.RoomDown(Some(pid))
              // unreachable
              process.PortDown(..) -> npc.RoomDown(None)
            }
          })
        let state =
          npc.State(
            name:,
            pid: process.self(),
            subject:,
            room:,
            status: npc.Alive(5),
            tick_ms: 1000,
          )
        actor.initialised(state)
        |> actor.selecting(selector)
        |> actor.returning(subject)
        |> Ok
      })
      |> actor.on_message(npc.handle_message)
      |> actor.named(process.new_name(id))
      |> actor.start

    case result {
      Ok(actor.Started(pid:, data: subject)) -> {
        // Send the join and the first tick once the actor is running, so the
        // initialiser only has to build the state.
        actor.send(subject, npc.Enter)
        actor.send(subject, npc.Tick)
        Ok(actor.Started(pid:, data: subject))
      }
      Error(error) -> Error(error)
    }
  })
  // A dead NPC stops normally, and only an abnormal exit is a crash to restart.
  |> supervision.restart(supervision.Transient)
}

pub fn world_child(
  name: process.Name(world.Message),
  rooms: List(room.Def),
) -> supervision.ChildSpecification(Subject(world.Message)) {
  let rooms = dict.from_list(list.map(rooms, fn(r) { #(r.id, r) }))
  let state = world.State(rooms:, players: dict.new())
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(_, pid, _) -> world.Down(Some(pid))
            // unreachable
            process.PortDown(..) -> world.Down(None)
          }
        })
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(world.handle_message)
    |> actor.named(name)
    |> actor.start
  })
}

// A supervisor with the room actors restored on failure. The world is
// supervised separately by the caller, so that tests can take it down without
// taking the rooms with it.
pub fn rooms_supervisor(rooms: List(room.Def)) -> static_supervisor.Builder {
  list.fold(
    rooms,
    static_supervisor.new(static_supervisor.OneForOne),
    fn(builder, def) { static_supervisor.add(builder, room_child(def)) },
  )
  |> static_supervisor.restart_tolerance(intensity: 5, period: 10)
}
