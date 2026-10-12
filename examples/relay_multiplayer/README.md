# Relay Arena

Two Rune windows share a small 2D arena through the self-hosted
[`rune_relay`](../../rune_relay/README.md) using UDP gameplay and reliable room
controls. Each player controls one
square with **WASD or the arrow keys**. The blue player hosts the game; the orange
player joins it. Your square has a white outline and a `YOU` label.

The host creates the player entities, applies both players' input, and publishes
their positions with stable network IDs. The guest sends input to the host and
updates its own ECS entities from the host's snapshots. The relay only forwards
messages; it does not simulate the game.

## Build and play

For a complete local test, run `launcher.bat` on Windows or `sh launcher.sh`
on Linux, then select **Relay Arena** in the **2D** tab. The launcher builds
the relay and game once, starts a relay on an available loopback port, and
opens two game windows with a host and guest already connected. Move with
WASD or the arrow keys. Close both windows to stop the relay and return to
the launcher. In prebuilt mode, both `build/rune_relay` and
`build/relay_multiplayer` must be present (with `.exe` on Windows).

The launcher session loads `rune_relay.json` from the repository root and
overrides `listen` with `127.0.0.1:0` to choose a free local port. It does not
use or stop another relay already running. Session logs are saved in a unique
`build/relay-session-*` directory; startup errors appear in the terminal and
launcher. `RUNE_EXAMPLE_ARGS` applies to both game processes, for example
`--scripted --run-seconds 15`. The launcher supplies `--host`, `--join`, and
`--server`; those options and `--capture` cannot be forwarded in this mode.
If a console directory is forwarded, the host and guest use its `relay-host`
and `relay-guest` subdirectories so each has a separate console inbox.

To use the host/join menu or a remote relay, start the programs directly:

Run from the repository root. On Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
odin build rune_relay -linker:msvc -collection:rune=rune -out:build/rune_relay.exe
odin build examples/relay_multiplayer -o:none -linker:msvc -collection:rune=rune -out:build/relay_multiplayer.exe
```

Start the relay in a separate terminal, then open two copies of the example:

```powershell
# Terminal 1: relay
.\build\rune_relay.exe

# Terminal 2: first player
.\build\relay_multiplayer.exe

# Terminal 3: second player
.\build\relay_multiplayer.exe
```

The example opens a host/join menu without connecting to the relay. In the first
window, click **Host game**, then **Copy code** to copy the room's 16-character
code. In the second window, click the **Room code** field, paste with Ctrl+V,
and click **Join game**. Lowercase codes and surrounding pasted whitespace are
accepted. Join is available once the code and relay address are valid.

The **Relay address** field defaults to `127.0.0.1:7777`; both players must use
the same relay. The example does not start the relay automatically. Connection
and room errors appear in the menu so you can correct the address or code and
retry. **Cancel** returns from an in-progress connection attempt.

Click a game window to give it keyboard focus. Both windows show the same two
players; the role badge and white player outline identify which one you control.
The stats panel is visible by default; **F2** toggles it in the focused window.
It shows peer ping, relay ping, round-trip jitter, FPS, upload/download rates
and packets per second, UDP receive loss, input/state rates, and input backlog.
Peer ping measures the round trip through the relay to the other game, including
its update loop, and becomes unavailable after three seconds without a reply.
Relay ping measures the round trip to the relay itself.
Traffic rates count protocol bytes over the previous second, including controls
and probes, without IP or socket headers. Receive loss is cumulative for this
connection and only counts UDP gameplay gaps after they leave the 64-packet
reordering window; `--` means there is no finalized sample or UDP is inactive.
Jitter is the smoothed change between consecutive peer round trips. Backlog is
queued guest input on the host and unacknowledged predicted input on the guest.

Click **Leave game** or press Escape to return to the menu. A departing guest's
entity is removed, and the host can wait for a new guest. When the host leaves,
the guest sees that the room has closed and can click **Return to menu**. Close
the window, or press Escape from the idle menu, to quit. Tab selects menu
controls, Enter activates them or submits an edited code, and Shift+Tab moves
backward.

On Linux:

```sh
mkdir -p build
odin build rune_relay -collection:rune=rune -out:build/rune_relay
odin build examples/relay_multiplayer -o:none -collection:rune=rune -out:build/relay_multiplayer
# Run each command in a separate terminal.
./build/rune_relay
./build/relay_multiplayer
./build/relay_multiplayer
```

The default relay endpoint is `127.0.0.1:7777`. For another machine, start the
relay with `--listen 0.0.0.0:7777`, allow port 7777 for both TCP and UDP through
the firewall, and
enter `<relay-address>:7777` in each player's Relay address field. See
[networking](../../docs/networking.md) for deployment and transport limits.

## Direct and automated runs

The existing command-line options skip the menu and connect directly. With the
relay running, start these in separate terminals:

```powershell
.\build\relay_multiplayer.exe --host
.\build\relay_multiplayer.exe --join 0123456789ABCDEF
```

Replace the sample code with the host's room code. Add
`--server <relay-address>:7777` for a remote relay. Headless mode requires
`--host` or `--join`.

Gameplay defaults to UDP; room creation, joining, departure, and closure remain
reliable over TCP. Both transports use the same relay address and port. The
footer shows `UDP` once negotiation completes, and the `State:` log reports
`transport=udp` with datagram counters. A blocked UDP route fails the session
with a connection error after five seconds rather than silently using TCP.
For a comparison or a TCP-only relay, pass `--transport tcp` to both clients.
The launcher forwards that flag through `RUNE_EXAMPLE_ARGS`; without it,
Relay Arena uses UDP automatically.

The visual example runs until its window is closed. Add `--run-seconds 30` for a
finite run measured from connection setup. Room creation and joining time out
after five seconds.

`--scripted` supplies repeatable movement for both roles; `--headless` runs the
same session and ECS replication code without opening a window. Use both for a
terminal smoke test:

```powershell
# Keep the relay running; run these in separate terminals.
.\build\relay_multiplayer.exe --host --headless --scripted --run-seconds 30
.\build\relay_multiplayer.exe --join 0123456789ABCDEF --headless --scripted --run-seconds 20
```

Headless mode defaults to fifteen seconds unless `--run-seconds` is specified.
Without `--scripted`, a headless player sends neutral input and remains still.
It exits immediately if the room closes or the connection fails.
The terminal reports entity IDs, positions, and input/snapshot counts. A
once-per-second `Network:` line also reports ping, jitter, traffic, receive loss,
probe timeouts, and duplicate/reordered/invalid/dropped UDP counts; `-1` marks
an unavailable latency or loss sample. You can
also join a visual host with a scripted headless guest, or add `--scripted` to a
visual window to observe automatic movement. Run `--help` for all options.

After building the relay and example, the launcher's optional process checks
exercise automatic host/guest setup and cleanup after a failed host. Run from
the repository root on Windows:

```powershell
odin test examples/launcher -o:none -linker:msvc -collection:rune=rune -define:RELAY_SESSION_SMOKE=true -define:ODIN_TEST_THREADS=1 -out:build/launcher_relay_process_test.exe
```

On Linux, omit `-linker:msvc` and `.exe`. Add
`-define:RELAY_SESSION_WINDOWED=true` to run hidden game windows instead of
headless clients, or `-define:RELAY_SESSION_PREBUILT=false` to check the build
and launch flow as well.

## How replication works

- [main.odin](main.odin) parses connection options and runs the menu, Rune window,
  or headless loop.
- [menu.odin](menu.odin) builds the host/join menu, validates fields, and provides
  session controls.
- [connection.odin](connection.odin) dials the relay on a worker thread so the
  menu stays responsive during connection attempts.
- [game.odin](game.odin) owns room events, input validation, player lifecycle,
  authoritative movement, and snapshot delivery.
- [prediction.odin](prediction.odin) shares movement math, keeps bounded input
  history, reconciles predicted movement, and smooths displayed positions.
- [wire.odin](wire.odin) adds the host's processed-input acknowledgement to
  snapshots without changing the shared replication format.
- [draw.odin](draw.odin) queries `replication.Identity` and `ecs.Transform` to
  draw the replicated players.
- [stats.odin](stats.odin) draws the F2 panel and samples input/state rates;
  [peer_stats.odin](peer_stats.odin) measures peer round trips with bounded probes.
- [project.json](project.json), [scenes/main.scene.json](scenes/main.scene.json),
  and [input/default.input.json](input/default.input.json) configure the window,
  camera, and movement bindings.
- [`rune:replication`](../../rune/replication) encodes input and position
  snapshots and applies snapshots to an ECS world.

Network IDs belong to the host and are independent of the entity handles in
each local world. Input contains a sequence number and two axes limited to
`-1`, `0`, or `1`. The guest samples and predicts movement at 60 Hz, using the
same diagonal normalization and arena clamps as the host. Each command is one
fixed movement step. Every input packet repeats up to 120 of the oldest
unacknowledged commands, allowing the next packet to repair loss. The host
ignores duplicate prefixes and queues only a contiguous new suffix; it never
acknowledges across a missing step. Snapshot ticks prevent an older or reordered
snapshot from replacing newer state.

The host queues validated commands and earns movement
allowances from its monotonic clock at 60 per second, independently of the
renderer's frame-delta clamp. It retains up to 256 unused allowances, including
time elapsed while input packets are missing, and spends up to eight per fixed
update. Each simulated
command spends one allowance, preserving input order and bounding movement by
elapsed host time. This prevents a window stall from leaving a permanent queue
delay. After 250 ms without fresh input, it drops queued commands and restores
the receive sequence to the last simulated acknowledgement, so the guest can
repeat any discarded steps without losing movement.

The host sends authoritative snapshots at 20 Hz. Each includes the last input
sequence it actually simulated, rather than the last packet it received.
The guest restores that authoritative position, discards acknowledged commands,
and replays the remaining commands once. Input history and the host's queue
are each limited to 256 commands. UDP data is sent immediately, without a
reliable queue. Temporary backpressure drops a datagram; repeated input and
later full snapshots repair it. TCP controls and optional TCP gameplay also
flush immediately with packet coalescing disabled.

Local movement does not wait for a snapshot. Small host corrections fade out
through a display offset; the guest interpolates the host's network snapshots
over 50 ms. The host draws both players directly from its 60 Hz simulation,
without waiting for its outbound snapshots. Large corrections snap immediately.
Smoothing affects only drawing, so it cannot feed back into authoritative
movement or prediction. Session
closure, departure, and reconnect reset the prediction and display history.

The once-per-second `State:` log includes `pending` input commands, the last
processed input `ack`, the active transport, and UDP sent/received counters,
so queue buildup and transport selection are visible during latency checks.

A snapshot also contains the host tick and the full set of network IDs,
owning peer IDs, and 2D positions. The guest creates missing entities, updates
existing ones, and removes entities absent from the next snapshot. A replacement
guest receives a new player ID.

Input batches and snapshots have explicit versions and use big-endian encoding,
including the bits of the finite 32-bit floating-point positions. The host
validates input from the current guest; the guest accepts snapshots only from
host peer 1. Malformed packets are rejected, redundant input prefixes are
ignored, and stale snapshots cannot replace newer state.
Guests also check that each snapshot contains the host and their own player,
with positions inside the arena, and reject acknowledgements that are stale or
refer to an input they have not sent. The example's snapshot envelope is seven
bytes: version 1, kind 3, an acknowledgement-present byte, and a big-endian
`u32` input sequence, followed by the unchanged shared snapshot payload.

The shared replication layer supports identities and 2D positions for up to
eight entities. Prediction and smoothing here are specific to this two-player
movement example. Replication of arbitrary ECS components, reconnect/resume,
and host migration remain future work.
