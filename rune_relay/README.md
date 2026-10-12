# Rune Relay

Rune's standalone room relay forwards guest input to a game host and
host-owned state to guests. Rooms stay in memory; the relay does not simulate
gameplay or require a database, renderer, or graphics context.
TCP carries room controls; clients can negotiate UDP for realtime data on the
same IP address and port. The server enables UDP by default and also supports
clients using TCP only.

Source layout:

- `main.odin`: command-line entry point and server loop.
- `server/server.odin`: rooms, connections, forwarding, and the server lifecycle.
- `server/udp.odin`: authenticated UDP binding, replay filtering, and forwarding.
- `../rune/network/`: game client API and shared wire protocol and transport.

The `server` package owns `server_start`, `server_update`, and `server_stop`.
Games use `rune:network` to connect, create/join rooms, and exchange bytes.
Each update flushes forwarded TCP packets for every connection before returning,
including recipients visited earlier in the loop, so connection order adds
no extra relay polling interval in either direction.
Bound UDP recipients receive data immediately through the shared UDP socket.
UDP loss does not move realtime data into TCP; games handle loss and reordering.

Build and run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
odin build rune_relay -o:speed -linker:msvc -collection:rune=rune -out:build/rune_relay.exe
.\build\rune_relay.exe --listen 127.0.0.1:7777
```

On Linux:

```sh
mkdir -p build
odin build rune_relay -o:speed -collection:rune=rune -out:build/rune_relay
./build/rune_relay --listen 127.0.0.1:7777
```

The relay automatically reads `rune_relay.json` from the current working
directory when that file exists. The repository's [sample configuration](../rune_relay.json)
keeps the built-in defaults: loopback port 7777, 128 connections, 64 rooms,
a 30-second idle timeout, 256 combined TCP/UDP packets per second per connection,
and enabled UDP. Its
[`$schema` reference](../schemas/relay.schema.json) provides editor validation.

Choose another file with `--config <path>`; relative paths also resolve from the
current working directory, not from the executable's directory. For example:

```sh
./build/rune_relay --config rune_relay.json --listen 0.0.0.0:7777
```

Command-line settings override JSON settings regardless of argument order.
Omitted JSON keys retain the built-in defaults. A missing automatic file uses
those defaults; a missing explicitly selected file, invalid JSON, unknown keys,
wrong types, or invalid values cause startup to fail before listening. `--help`
shows usage without loading any configuration file.
The file's settings must be valid before command-line overrides are applied;
`max_rooms` cannot exceed `max_connections` in either the loaded settings or the
overridden settings. Lowering the connection limit below 64 also requires
lowering the room limit, because an omitted `max_rooms` retains its default of 64.

Settings are loaded only at startup. Restart the relay after editing the file;
restarting closes existing rooms. The optional `run_seconds` JSON number or
`--run-seconds` option selects a finite run greater than zero and at most 86,400
seconds; omit both to run indefinitely. Stop with Ctrl+C. Use `--help` for all
settings or `--run-seconds 10` for a finite smoke test.

Set `"udp_enabled": false` or pass `--no-udp` to disable UDP; `--udp` enables it.
The last UDP flag wins, and command-line flags override the file. An enabled
relay must bind both TCP and UDP to the chosen endpoint before startup succeeds.
Public hosting therefore requires forwarding and allowing both protocols on
that port. Clients opt in with `network.connect(&client, endpoint, use_udp = true)`;
the SDK's default remains TCP. A requested UDP connection fails if negotiation
is unavailable or cannot finish within five seconds.

UDP authentication uses a random 128-bit token issued over the client's TCP
connection. Binding must come from that TCP peer's IP address; subsequent data
must also match the bound UDP source port. Binding retries keep NAT mappings
alive and permit port changes, while data rejects duplicates and accepts late
packets within a 64-sequence replay window. Closing or timing out the TCP
connection revokes its UDP session; room controls remain on TCP throughout.

For embedded relay use, a zero-value `Server_Config` enables UDP. To disable it
programmatically, set both `udp_enabled = false` and `udp_configured = true`;
the latter distinguishes an explicit choice from an omitted setting.

The loop requests a two-millisecond sleep between polls and flushes forwarding
before sleeping, regardless of connection order. On Windows it requests
one-millisecond timer resolution while running, then releases that request on exit. A rejected
request prints a warning and retains the system timer; scheduling can still vary.

See the [networking guide](../docs/networking.md) for the protocol, limits,
Linux hosting, verification, and deployment scope, or try the
[two-player example](../examples/relay_multiplayer/README.md).
