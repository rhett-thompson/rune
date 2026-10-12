# Self-hosted room relay

Rune's standalone [`rune_relay`](../rune_relay/README.md) application provides a
room relay with reliable TCP session controls and authenticated UDP gameplay.
The optional `rune:network` package provides the game client API
and shared wire protocol and transport. A player hosts the simulation: guests
send commands to that player, and the host sends authoritative state back. The
relay forwards opaque bytes; it does not load scenes, run physics, or decide
game rules. It requires only Odin's core library, with no database, raylib,
R3D, or graphics context.

Room creation, joining, departure, and closure use reliable TCP. Gameplay can
use UDP, allowing later snapshots and redundant input batches to arrive without
waiting for a lost datagram. Relay Arena enables UDP by default and adds local
prediction, reconciliation, and presentation smoothing. Automatic replication
of arbitrary ECS components, host migration, matchmaking, transport encryption,
and reconnect/resume remain future work.

The executable entry point is `rune_relay/main.odin`; room management and the
server lifecycle (`server_start`, `server_update`, and `server_stop`) live in
the `rune_relay/server` package. Game clients continue importing `rune:network`.

## Build and run

From the Rune checkout on Windows:

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

The default endpoint is `127.0.0.1:7777`. Use `--listen 0.0.0.0:7777` to accept
IPv4 connections on other interfaces, or a bracketed IPv6 endpoint such as
`--listen '[::]:7777'`. IPv4 and IPv6 listeners are separate; IPv6 dual-stack
behavior depends on the OS. Allow the chosen **TCP and UDP** port through the server's
firewall and forward it on the router when necessary. Players connect outbound
to the relay, so the player acting as game host needs no inbound port forwarding.
The UDP listener uses the same numeric address and port as TCP, including the
OS-selected port when `listen` uses port zero. UDP is enabled by default;
`--no-udp` or `"udp_enabled": false` starts a TCP-only relay.

The relay automatically loads `rune_relay.json` from its current working
directory when present. The repository includes a [sample file](../rune_relay.json)
using the built-in defaults and an optional `$schema` string referring to
[`schemas/relay.schema.json`](../schemas/relay.schema.json) for editor validation.
Omitted keys retain the built-in defaults. If the automatic file is missing,
the relay starts with those defaults.

Use `--config <path>` to select a different file. Relative configuration paths
resolve from the current working directory, not the executable's directory.
Command-line settings override JSON settings regardless of argument order:

```sh
./build/rune_relay --config rune_relay.json --listen 0.0.0.0:7777
```

A missing explicitly selected file or an invalid existing file causes startup
to fail before the relay listens. Configuration files reject unknown keys,
wrong types, and out-of-range values; `$schema` is the only optional metadata
key. The file's settings must be valid before command-line overrides are
applied, including `max_rooms` not exceeding `max_connections` after omitted
defaults are filled in. The overridden settings are validated again. Lowering
the connection limit below 64 also requires lowering the room limit; an omitted
`max_rooms` retains its default of 64. `--help` prints usage without loading a
file, including when `--config` is supplied.

The server keeps all rooms in memory. Stop it with Ctrl+C; restarting closes all
sessions. Settings are loaded only at startup, so restart after changing a file.
`--run-seconds 10` is useful for a finite smoke test. Omit `run_seconds` and its
command-line option to run indefinitely. `--help` lists the available settings:

| JSON key | Command-line option | Default | Limits and meaning |
| --- | --- | --- | --- |
| `listen` | `--listen` | `127.0.0.1:7777` | Numeric IP endpoint; port 0..65535, with 0 choosing a free port |
| `udp_enabled` | `--udp` / `--no-udp` | `true` | Enable UDP gameplay on the same endpoint as TCP |
| `max_connections` | `--max-connections` | 128 | 1..4096 connections, including clients that have not joined a room |
| `max_rooms` | `--max-rooms` | 64 | 1..4096 simultaneous rooms; cannot exceed the connection limit |
| `timeout_seconds` | `--timeout-seconds` | 30 | Integer 5..3600; idle seconds before disconnecting a connection |
| `packets_per_second` | `--packets-per-second` | 256 | Integer 8..10000; per-connection frame limit, including control messages |
| `run_seconds` | `--run-seconds` | Indefinite | Optional number greater than 0 and at most 86400; fractional seconds allowed |

For code embedding the relay, a zero `Server_Config` enables UDP by default.
Explicitly disable it with `udp_configured = true, udp_enabled = false`.

Each connection has about 67 KiB of application buffers. A room supports two to
eight players, including the host. The server reports connection, room, forwarding,
rejection, and disconnect counters every ten seconds. It does not log room codes
or gameplay payloads. A connection limit rejection closes the incoming socket;
a room capacity rejection returns an error event to the connected client.

## Two-player example

See [the relay example](../examples/relay_multiplayer/README.md). Selecting
**Relay Arena** in the launcher's **2D** tab starts the relay and two game
windows, then connects the host and guest automatically. The session uses an
available loopback port while loading the other settings from `rune_relay.json`.
Close both game windows to stop that relay and return to the launcher.

For a manual or remote test, start the relay separately, then run two copies
of `relay_multiplayer` without arguments. Each
opens a host/join menu without contacting the relay. Click **Host game** in one
window, then **Copy code**. Paste the code into the other window's **Room code**
field and click **Join game**. Both players must use the same **Relay address**,
which defaults to `127.0.0.1:7777`. The example does not start the relay itself.

The host displays a random 16-character room code. Connection and room errors
appear in the menu for correction and retry; **Cancel** abandons a connection
attempt. WASD or the arrow keys move your player; a white outline identifies it.
The guest sends input, and only the host advances both players and publishes
their state. Both windows draw their local ECS entities using the same stable
network IDs.

**Leave game** or Escape returns a player to the menu. The host removes a guest's
entity when they leave and can accept a replacement guest. Leaving or closing
the host closes the room; the guest displays that state with **Return to menu**.
For direct or automated runs, `--host` and `--join <code>` skip the menu, with
optional `--server <address>:7777`. Add `--headless --scripted --run-seconds 10`
to either role to exercise its session and ECS lifecycle without opening a
window.

## Basic entity replication

The optional `rune:replication` package provides portable movement-input and
2D-position snapshot formats, plus a `Replica` that applies snapshots to an ECS
world. It depends on `rune:ecs` and `rune:network`; the standalone relay continues
to depend only on Odin core libraries. This is an explicit small replication
layer for identities and positions.

Register the identity component before creating players:

```odin
import "rune:ecs"
import "rune:replication"

assert(replication.register(registry))
// The host assigns a nonzero network ID and the owning relay peer.
assert(ecs.add(world, registry, player, replication.Identity{id = 1, owner_peer = 1}))
assert(ecs.add(world, registry, player, ecs.Transform{position = {320, 400, 0}, scale = {1, 1, 1}}))
```

The host calls `snapshot_from_world(world, tick)`, encodes the returned snapshot
with `encode_snapshot`, and sends those bytes to the guests through
`network.send`. Guests decode snapshots received from host peer 1 and call
`apply_snapshot(&replica, world, registry, snapshot)`. A full snapshot creates
missing entities, updates `Identity` and `Transform.position`, and removes
replicated entities absent from the next snapshot. Local ECS handles can differ
between machines; `Identity.id` is the stable cross-client identifier.

`Replica` tracks only entities it creates. `clear(&replica, world)` removes those
entities when a session ends and resets the accepted tick. It preserves entities
owned by game code, including children attached to a replicated player. Snapshot
application rejects invalid or stale snapshots before changing the world.

The payload limits are eight entities per snapshot, nonzero network and owner
IDs, unique network IDs, and finite positions. An input sample contains a
sequence number and two signed axes in `[-1, 1]`. The example sends a command
for each 60 Hz fixed step. Each packet repeats up to 120 of the oldest
unacknowledged commands; the host accepts only a contiguous new suffix and
ignores redundant prefixes. A newer packet repairs loss and reordering without
skipping an unsimulated movement step. The host earns 60 movement allowances per second
from monotonic wall time, including time discarded by the renderer's delta
clamp. It banks at most 256 unused allowances and spends at most eight per fixed
update. Retaining elapsed time while inputs are missing lets a repaired batch
catch up without creating permanent delay. Each command spends one allowance;
movement cannot exceed the host time available. Input expiry clears queued
commands and restores the receive sequence to the last simulated acknowledgement,
allowing unacknowledged steps to be repeated.
Sequence numbers and snapshot ticks use wrap-aware comparisons.
The example additionally validates the sender and
input sequence, normalizes diagonal movement, clamps positions to the arena,
and expires guest input after 250 ms without a fresh command. The host advances
the game at 60 Hz and sends snapshots at 20 Hz. Snapshots acknowledge the last
input actually simulated, allowing the guest to predict immediately and replay
unacknowledged commands after a correction. The guest interpolates the host's
network snapshots over 50 ms, and small local corrections fade visually. The
host draws its authoritative positions immediately for both players. These
display changes do not alter simulation. Each game must provide its own
application-level checks.

The example's guest additionally requires exactly one host player and one player
owned by its own relay peer, with both positions inside the arena, before
applying a snapshot.

Input payloads are eight bytes: version, kind, a big-endian `u32` sequence, and
two signed axis bytes. Snapshot payloads have a seven-byte header (version,
kind, big-endian `u32` tick, entity count), followed by sixteen bytes per entity:
big-endian network ID, owning peer ID, and two IEEE 754 `f32` positions. Positions
are sent as their explicitly encoded 32-bit bit patterns. The maximum snapshot
is 135 bytes, within the relay's 1,024-byte message limit.

The movement example wraps the shared snapshot in a seven-byte envelope:
version 1, kind 3, an acknowledgement-present byte (0 or 1), and a big-endian
`u32` processed input sequence. An absent acknowledgement has sequence zero.
Its maximum payload is 142 bytes. The shared replication codec remains unchanged;
other games can continue sending its snapshot format directly.

## Client API

```odin
import "rune:network"

client: network.Client
err := network.connect(&client, "127.0.0.1:7777", use_udp = true)
assert(err == nil)
defer network.disconnect(&client)

assert(network.create_room(&client, 2))
// Or, on a guest: network.join_room(&client, "0123456789ABCDEF")

// Call during the game's update loop, with a bounded event budget per frame.
for _ in 0..<64 {
    packet, available, ok := network.poll(&client)
    if !ok {break} // disconnected, timed out, or invalid relay response
    if !available {break}
    // Welcome/Joined confirms membership. Data contains game-defined bytes.
    // Peer_Joined/Peer_Left identifies a room member through packet.peer.
}
```

`connect` performs synchronous DNS resolution and TCP connection establishment;
call it outside a latency-sensitive frame update. The remaining operations use
nonblocking sockets. All operations on a given client or server belong on one
thread. `poll` sends queued messages and heartbeats, receives events, and detects
timeouts. Continue polling even when there is no game traffic. Clients send a
heartbeat every second and disconnect after thirty seconds without a relay
response; choose a server idle timeout longer than one second.

The API defaults to TCP for existing callers. `use_udp = true` requests an
authenticated UDP session during connection setup. `poll` negotiates a random
128-bit token over TCP, binds the client's UDP endpoint, and retries the bind
until its acknowledgement arrives. Gameplay may briefly use TCP during this
startup negotiation; once `udp_ready` is true, `send` uses UDP. An unavailable
or blocked UDP route fails after at most five seconds with `udp_failed = true`;
it does not silently remain on TCP. UDP binding heartbeats keep idle mappings
active, and losing the UDP path also times out. `udp_requested`, `udp_ready`,
and the sent/received/dropped datagram counters expose the connection state.

`network.stats(&client)` returns a measurement snapshot without allocation or
mutation. It includes relay round-trip time and variation, lifetime sent/received
protocol bytes and packet counts, rolling one-second traffic rates, and UDP
receive loss. Relay RTT uses the actual socket send time of a TCP heartbeat or
a matching UDP bind acknowledgement. Packet counts include TCP frames and UDP
datagrams; byte counts exclude IP, TCP/UDP, and link-layer headers.

UDP loss counts only relay-to-client gameplay sequence gaps that have left the
64-datagram reordering window. Check `udp_rx_expected > 0` before displaying a
percentage. Duplicate, reordered, invalid, and locally dropped datagrams have
separate counters. Stats survive disconnect for diagnostics and reset on the
next connection attempt. The [Relay Arena example](../examples/relay_multiplayer)
adds a peer ping over gameplay transport and displays these readings with F2.

`create_room` and `join_room` queue a request. Wait for `Welcome` or `Joined`,
respectively, before sending gameplay messages. These events set `peer_id`,
`room_code`, `is_host`, and `status == .In_Room`. The host's peer ID is always 1;
guests receive increasing IDs that are not reused within the room. A joining
guest also receives `Peer_Joined` for every existing member, including the host.

To send bytes from a guest:

```odin
network.send(&client, input_bytes, 1) // target the host
```

To publish state from the host:

```odin
network.send(&client, state_bytes)             // all guests
network.send(&client, state_bytes, guest_id)   // one guest
```

Messages contain at most 1,024 bytes. For UDP, `send` attempts one datagram
immediately. Packet loss, reordering, and duplication are possible; transient
socket backpressure drops the datagram and increments `udp_dropped` rather than
building a reliable queue. A true result means the send was attempted, not that
the peer received it. TCP sends instead retain bounded unsent bytes for `poll`
to retry, and disable packet coalescing. `send` returns false for an invalid
target, oversized payload, wrong state, full TCP output buffer, or fatal socket
error. Check its result and keep application history bounded.
The relay disconnects peers whose bounded output queues cannot keep up. On
receipt, `packet.peer` is the sender assigned by the relay, never a client-supplied
identity. Guests can send only to the host; guests cannot send state directly to
each other. The host must validate the meaning and limits of all guest commands.
Use an explicit portable encoding for game data rather than sending raw Odin
struct memory.

`Packet` owns its payload: use `packet.payload[:packet.payload_size]`. Keeping an
event remains valid after the next `poll`. `Error` events have one payload byte
containing `Error_Code`: invalid request, unknown room, full room, full server,
not in a room, or forbidden routing. Failed create/join requests return the
client to `.Connected`, allowing another attempt. `Pong` is a heartbeat event.
When the host disconnects, guests receive `Room_Closed` and reset to
`.Disconnected`. Abrupt relay failure instead makes `poll` return `ok == false`.
Reconnect creates a new connection and room membership; there is no session
restoration or host migration.

## Hosting on Linux

Build the executable on the target system (or another compatible Linux AMD64
system), copy it to `/opt/rune/rune_relay`, and run it as a dedicated account.
This service example assumes the `rune` user and group already exist:

```ini
# /etc/systemd/system/rune-relay.service
[Unit]
Description=Rune room relay
After=network.target

[Service]
User=rune
Group=rune
ExecStart=/opt/rune/rune_relay --listen 0.0.0.0:7777 --max-connections 128 --max-rooms 64
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
LimitNOFILE=1024

[Install]
WantedBy=multi-user.target
```

Install and start it with `sudo systemctl daemon-reload` and
`sudo systemctl enable --now rune-relay`. Read counters and startup errors with
`journalctl -u rune-relay`. This setup needs no persistent data directory.
To use a file with this service, place it at an explicit path such as
`/etc/rune/relay.json` and add `--config /etc/rune/relay.json` to `ExecStart`.
The existing command-line options still override matching file values. Restart
the service after editing the file; an executable's directory does not determine
where the automatic `rune_relay.json` is loaded.

The prototype has no TLS, account authentication, or operator access key. Room
codes use 64 bits of OS cryptographic randomness and act as invitations, but TCP
traffic and invitations are unencrypted. For private remote testing, put the
relay behind a VPN that carries both TCP and UDP. UDP session tokens associate
datagrams with an existing connection; they do not encrypt gameplay or provide
account authentication. A publicly exposed deployment needs
transport encryption and additional admission/abuse controls. The packet and
queue limits bound application resources; they do not replace network-level
connection and bandwidth limits.

## Protocol and verification

Version one frames are a two-byte big-endian body length, four magic bytes
`RUNE`, a one-byte version, a one-byte kind, a four-byte big-endian peer ID, and
an optional payload. Body lengths range from 10 to 1,034 bytes. Create requests
contain a one-byte room capacity; join requests contain the 16 ASCII hex bytes.
Request `Data.peer` means destination; response `Data.peer` means authenticated
sender. TCP segmentation and coalescing do not change these message boundaries.

UDP negotiation uses TCP `UDP_Enable` (kind 6, empty payload) and `UDP_Session`
(kind 23, 16-byte random token). UDP datagrams start with `RUNE`, version 2,
datagram kind (bind 1, bind acknowledgement 2, or data 3), the token, and a
big-endian `u32` sequence. The header is 26 bytes. Bind messages contain only
the header; data contains exactly one version-one `Data` frame. The maximum
datagram is 1,062 bytes, below 1,200. Endpoint and token checks authenticate
association, and a 64-sequence replay window admits bounded reordering while
rejecting duplicates. TCP disconnect or room closure invalidates the association.

Relay Arena input batches use version 1, kind 4, a one-byte command count,
and one to 120 shared eight-byte input commands in consecutive sequence order.
The maximum batch payload is 963 bytes. Snapshots retain the existing
processed-input acknowledgement envelope; stale snapshots cannot overwrite
newer state. Loss beyond the bounded prediction history fails the session
instead of acknowledging movement the host never simulated.

Run the focused checks on Windows:

```powershell
odin test rune/network -o:none -linker:msvc -collection:rune=rune -out:build/network_test.exe
odin test rune/replication -o:none -linker:msvc -collection:rune=rune -out:build/replication_test.exe
odin test examples/relay_multiplayer -o:none -linker:msvc -collection:rune=rune -out:build/relay_multiplayer_test.exe
odin test rune_relay -o:none -linker:msvc -collection:rune=rune -out:build/rune_relay_config_test.exe
odin test rune_relay/server -o:none -linker:msvc -collection:rune=rune -out:build/rune_relay_test.exe
odin run tools/relay_validation -o:none -linker:msvc -collection:rune=rune -out:build/relay_validation.exe
odin run tools/replication_validation -o:none -linker:msvc -collection:rune=rune -out:build/replication_validation.exe
```

On Linux, omit `-linker:msvc` and `.exe`. Both platform validation helpers build
the standalone server, discover and run the relay and replication validators,
and run the network, replication, relay configuration, and server unit tests.
The replication validator connects real clients to the relay and verifies input-driven host
movement, guest ECS snapshots, departures, replacement guests, and room closure.
The helpers also run the two-player example's gameplay tests;
`--all-examples` additionally builds its visual executable.
