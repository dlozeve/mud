# Multi-user dungeon

I built this project to teach myself the
[Erlang/OTP](https://www.erlang.org/) model for concurrency, using
[Gleam](https://gleam.run/). There are individual processes managing
each player, each room, and each NPC, communicating via messages.

It relies on the [gleam_otp](https://gleam-otp.hexdocs.pm/) and
[gleam/erlang/process](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
libraries for interop with OTP, along with
[glisten](https://glisten.hexdocs.pm/) for handling TCP connections.

## Actors

- **world actor:** holding the room graph and the player directory
- one **room actor** per room: holding that room's occupants
- one **NPC** actor per NPC
- a **glisten** listener that accepts TCP connections

All under a single static supervisor.

A connection is handled by its own process, which owns the `session`
state machine and runs the effects defined in `session`.
`runner.run_effects` turns those effects into sends to the world, the
current room, the socket, or a timer.

## Sequence diagrams

### Startup

`main` loads the map, builds the supervision tree, and starts the
listener.  Rooms start first, then the world, then the NPCs (each
joining their room), and finally the TCP listener.

```mermaid
sequenceDiagram
  autonumber
  participant Main as main
  participant ML as map_loader
  participant Sup as Supervision tree
  participant R as Room actors
  participant W as World
  participant N as NPC goblin
  participant G as Glisten listener

  Main->>ML: parse_rooms(read("maps/map.toml"))
  ML-->>Main: Map(rooms, entrance)
  Main->>Main: world_name = new_name("world")
  Main->>G: server_child_with_listener(world, entrance, 3000)
  G-->>Main: child spec + Listener(name)
  Main->>Sup: add rooms, world, NPC, and listener children
  Main->>Sup: static_supervisor.start()
  Sup->>R: start one named actor per room
  R-->>Sup: room pid + subject
  Sup->>W: start actor named "world"
  W-->>Sup: world pid + subject
  Sup->>N: start actor named "goblin"
  Sup->>N: send npc.Enter
  Sup->>N: send npc.Tick
  N->>R: process.named(entrance), monitor room
  N->>R: room.enter(entrance, occupant(goblin, Npc))
  Note over R: occupants[goblin_pid] = goblin
  Sup->>G: start listening on port 3000
  Note over G: ready to accept TCP connections
```

### A player connects and claims a name

The connection process starts in `AwaitingName`. A valid name moves it
to `Joining`; the world reserves the name and replies with the
entrance room, and the session then enters that room.

```mermaid
sequenceDiagram
  autonumber
  actor C as Client
  participant L as Glisten listener
  participant S as Session (connection process)
  participant W as World
  participant R as Room (entrance)
  participant N as NPC

  C->>L: TCP connect
  L->>S: start connection process, on_init(conn)
  S->>S: session.started() -> AwaitingName
  S-->>C: "Welcome to the dungeon! What is your name?"
  C->>S: "Alice" + newline
  S->>S: take_lines, valid_name -> Joining("Alice")
  S->>W: world.join("Alice", self(), entrance, replies)
  S->>S: schedule JoinTimeout after 5000 ms
  W->>W: players["alice"] = pid
  W-->>S: replies: Joined(Ok(entrance))
  W->>S: monitor player pid
  S->>S: InGame(Alice), effect EnterRoom(entrance, 0)
  S->>R: process.named(entrance) -> room pid
  S->>R: room.enter(entrance, occupant(Alice, pid, Player))
  S->>R: monitor room pid (room_watch)
  R->>R: occupants[pid] = Alice, monitor player pid
  R-->>S: listener: RoomMessage(entrance, YouAreIn(...))
  R-->>N: listener: RoomMessage(entrance, OccupantArrived("Alice", Player))
  S-->>C: "You are in the dungeon entrance." + exits
  Note over N: NPC ignores room events it does not act on
```

Failure branches handled by the same state machine:

- `Joined(Error(AlreadyLoggedIn))` or `Joined(Error(NoSuchRoom))`
  resets the session to `AwaitingName` and prints the reason (the name
  is case-insensitive).
- No reply within 5 seconds produces `JoinTimeout`: the session
  returns to `AwaitingName` and asks for a name again.
- If the room is not registered yet when entering, the session retries
  every 100 ms, up to 10 attempts, then disconnects.

### Looking around and listing occupants

Both commands are served entirely by the room actor; the session only
renders the event it receives back.

```mermaid
sequenceDiagram
  autonumber
  actor C as Client
  participant S as Session
  participant R as Room

  C->>S: "look" + newline
  S->>S: command.parse -> Look, player.decide_command
  S->>R: room.look(room_name, pid)
  R->>R: find occupant by pid
  R-->>S: RoomMessage(YouAreIn(name, description, exits))
  S-->>C: room name, description, and exits

  C->>S: "who" + newline
  S->>S: command.parse -> WhoIsHere, player.decide_command
  S->>R: room.who_is_here(room_name, pid)
  R->>R: partition occupants into players and NPCs
  R-->>S: RoomMessage(OccupantList(player_names, npc_names))
  S-->>C: "Alice is here." / "There is a goblin in the room."
```

### Talking to the room

A `say` is broadcast by the room. The speaker gets `YouSaid`, everyone
else in the room (players and NPCs) gets `OccupantSaid`. Each session
renders its own event, so messages are queued and delivered
asynchronously.

```mermaid
sequenceDiagram
  autonumber
  actor A as Alice's client
  participant SA as Alice's session
  participant R as Room
  participant SB as Bob's session
  actor B as Bob's client
  participant N as NPC

  A->>SA: "say hello" + newline
  SA->>SA: command.parse -> Say("hello"), decide_command -> Say action
  SA->>R: room.say(room_name, alice_pid, "hello")
  R->>R: find speaker by pid
  R-->>SA: RoomMessage(YouSaid("hello"))
  R-->>SB: RoomMessage(OccupantSaid("Alice", "hello", Player))
  R-->>N: RoomMessage(OccupantSaid("Alice", "hello", Player))
  SA-->>A: "You say: hello"
  SB-->>B: "Alice says: hello"
  Note over N: chat events are ignored by the NPC
```

### Moving between rooms

The world validates the exit and answers with the destination
room. The session then leaves the old room and enters the new one,
which re-registers the player and sends `OccupantLeft` /
`OccupantArrived` to the other occupants.

```mermaid
sequenceDiagram
  autonumber
  actor C as Client
  participant S as Session
  participant W as World
  participant R1 as Room (entrance)
  participant R2 as Room (corridor)
  participant O as Other occupants

  C->>S: "go north" + newline
  S->>S: command.parse -> Go(North), decide_command -> Move(North)
  S->>W: world.move(entrance, North, replies)
  W->>W: resolve entrance.north -> corridor
  W-->>S: replies: Moved(entrance, Ok(corridor))
  S->>S: InGame(player.room = corridor)
  S->>R1: room.leave(entrance, pid)
  R1-->>O: RoomMessage(OccupantLeft("Alice", Player))
  S->>R2: process.named(corridor), room.enter(corridor, occupant)
  S->>R2: monitor corridor pid (replace room_watch)
  R2-->>S: RoomMessage(YouAreIn(corridor, ...))
  R2-->>O: RoomMessage(OccupantArrived("Alice", Player))
  S-->>C: corridor name, description, and exits
  alt invalid exit
    W-->>S: replies: Moved(entrance, Error(NonExistingExit))
    S-->>C: "You can't go that way."
  end
```

### Quitting

`quit` is the one command that produces a `Stop` effect. The session
leaves the room, `runner` reports `Requested`, and the server stops
the glisten connection process. `on_close` runs once more; the extra
leave is harmless, and the world and room monitors also clean up the
pid when the process goes down.

```mermaid
sequenceDiagram
  autonumber
  actor C as Client
  participant S as Session
  participant R as Room
  participant L as Glisten
  participant W as World

  C->>S: "quit" + newline
  S->>S: command.parse -> Quit, effects [LeaveRoom, Stop]
  S->>R: room.leave(room_name, pid)
  R->>R: delete occupant, tell others OccupantLeft
  S->>S: runner sees Stop -> Error(Requested)
  L->>S: on_close, session.closed -> LeaveRoom
  S->>R: room.leave(room_name, pid) (already absent, no-op)
  L->>C: close connection
  S--xW: process exit -> DOWN, world removes player
  S--xR: process exit -> DOWN, occupant already removed
```

### Recovering from a room crash

The room supervisor restarts a crashed room with an empty occupant
map. Both the players and the NPC monitor their room, so they notice
the `DOWN` and re-enter the replacement. Names may not be registered
yet when the `DOWN` arrives, so both sides retry with bounded backoff.

```mermaid
sequenceDiagram
  autonumber
  participant R as Room
  participant RS as Room supervisor
  participant S as Session
  participant N as NPC

  R->>RS: abnormal exit
  RS->>R: start replacement room under the same registered name
  Note over S: monitor on the old room pid fires DOWN
  Note over N: monitor on the old room pid fires DOWN
  S->>S: RoomDown matches room_watch -> EnterRoom(current, 0)
  alt room name not registered yet
    S->>S: RetryEnter after 100 ms, at most 10 attempts
  else room is up
    S->>R: room.enter(current_room, occupant)
    R-->>S: RoomMessage(YouAreIn(...))
  end
  N->>N: RoomDown -> JoinRoom(0)
  alt room name not registered yet
    N->>N: Join(attempt + 1) after 1000 ms, at most 10 attempts
  else room is up
    N->>R: monitor room, room.enter(room, occupant(goblin, Npc))
  end
  Note over S,N: both are visible in the room again
```

## Try it

Start a local game server:
```sh
gleam run
```

Then in another terminal, you can use `netcat` to connect:
```sh
nc localhost 3000
```
You can do this several times to have multiple players.

## Tests

```sh
gleam test
```
