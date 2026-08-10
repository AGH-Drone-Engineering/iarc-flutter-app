# IARC 2026 — ground station

Flutter app (Android). Commands the drone swarm and plans the ground route
through the minefield.

```
phone ──USB──► ground ESP ──LoRa──► drone HAT ──UART──► Raspberry Pi
```

Wire protocol: **[PROTOCOL.md](PROTOCOL.md)**.

## Transports

Switchable at runtime in the Link tab, no rebuild. Identical message set on both.

| | LoRa (USB) | UDP (Wi-Fi) |
|---|---|---|
| Path | phone → ESP → LoRa → HAT → Pi | phone → Wi-Fi → Pi |
| Framing | LoRaCom `TYPE\|ID\|LEN\|PAYLOAD\|CRC16` | one message per datagram |
| Receive | `GETMSG` poll every 200 ms | pushed |

UDP is the fallback for when the ESP board isn't ready. The app listens on
`14650`; drones default to `raspi-usa-<id>.local:14660`, configured in the Link
tab and persisted. A drone is identified by source address, so each needs its
own — datagrams from unknown hosts are dropped with a rate-limited warning.

> The HAT bridges LoRaCom on GPIO17/18, not USB-CDC. Until that firmware
> changes, connect the phone through a USB-UART adapter to those pins.

## Tabs

| | |
|---|---|
| **Mission** | Commands, demo progress, fleet status, missing-ACK alerts |
| **Map** | Drone positions, tracks, mines, field |
| **Field** | The four field corners, any order |
| **Logs** | Session logs |
| **Link** | Transport, endpoints, diagnostics |
| **Path** | Ground route through the minefield |

## Commands

`START_DEMO` (hover altitude) · `START_MAIN` (4 corners + altitude) ·
`MOVE` (absolute `[lat, lon]`) · `LAND` · `RTH` · `STATUS`

Drones are `Bajer 1`–`Bajer 4` (ids 1–4); `0xFF` broadcasts to all.

**ACK.** Every command carries a sequence number and the drone answers
`ACK`/`NACK` with it inside 2 s. Three attempts reusing the same number, so the
drone can filter duplicates; after that the operator gets an alert. Broadcasts
are tracked per drone.

**Demo.** The app holds the choreography; the drone stores no routine. The
`START_DEMO` ACK carries the drone's position, the app lays a figure around that
anchor and issues it one vertex at a time:

```
ACK(lat,lon)      → MOVE to vertex 0
WAYPOINT_REACHED  → MOVE to the next vertex
NACK / no ACK     → RTH
MISSION_DONE      → done
```

Arrival advances the sequence, not the ACK — an ACK only means the `MOVE` was
accepted. Arrival itself is read from telemetry (a `HOVER` frame on the vertex),
not from `WAYPOINT_REACHED`, which is sent once, never acknowledged and carries
no position. *Settle on vertex* holds the drone there for a configurable pause
after arrival before the next `MOVE` goes out, so the next leg does not start on
the tail of the last one's overshoot; 0 s steps as soon as the arrival is
confirmed. Each drone has its own state and step counter, capped at 200. `Stop`
ends the sequence without sending RTH. The D-pad issues single `MOVE`s
independently, resolving direction + step distance against the drone's last
known position.

**Killswitch — not in this app.** Cutting motors is a hardware function of the
HAT (the ESP32-S3 drives `KILLSWITCH_FC_CTL` / `KILLSWITCH_PSU_CTL`). A kill
carried over Layer 2 would only work while the Pi is up and the mission process
alive — exactly when it isn't needed. `TELEM`'s `KILLED` state is still shown.

## Path planning

The Path tab turns field corners, `MINE` reports and `SCAN` coverage into a
ground route. Terrain no `SCAN` covers counts as mined, so a swarm that never
reports coverage yields no route rather than an unsafe one.

Two solvers, both run in a background isolate:

- **Grid** — port of `minefield_path/gridsolver.py`; maximises the competition
  score from `spec.txt`. Exports `path.txt` for the judges.
- **Voronoi** — Delaunay → Voronoi graph → bottleneck Dijkstra; maximises
  clearance from the nearest mine.

Recompute is manual — a full 40×150 field takes several hundred ms, so it does
not re-run on every incoming mine. Stale results are marked as such.

## Logs

JSONL, one file per app run, 20 sessions kept. Levels `TRACE` `INFO` `SENT`
`RECV` `WARN` `ERROR`, filterable by level, text and tag. Payloads that fail
protocol validation appear only at `TRACE`, in full and escaped. Idle polling
logs nothing.

## Voice

English and Polish, optionally prefixed with a drone (`drone 2`, `all`,
`Bajer 3`). Covers `START_DEMO`, `START_MAIN`, `LAND`, `RTH`, `STATUS`, and
`MOVE` with a direction and distance.

## Build

```bash
flutter pub get
flutter test          # 161 tests
flutter analyze
flutter build apk --release --split-per-abi
flutter run           # then pick a device
```

Needs Flutter with Dart SDK `^3.9.0`. **Android only** — iOS is not wired up.

Release: `git tag vX.Y.Z && git push origin vX.Y.Z`. CI builds per-ABI APKs plus
an AAB and attaches them to the GitHub release (~20 min).
