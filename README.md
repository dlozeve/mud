# Multi-user dungeon

I built this project to teach myself the
[Erlang/OTP](https://www.erlang.org/) model for concurrency, using
[Gleam](https://gleam.run/). There are individual processes managing
each player, each room, and each NPC, communicating via messages.

It relies on the [gleam_otp](https://gleam-otp.hexdocs.pm/) and
[gleam/erlang/process](https://gleam-erlang.hexdocs.pm/gleam/erlang/process.html)
libraries for interop with OTP, along with
[glisten](https://glisten.hexdocs.pm/) for handling TCP connections.

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
