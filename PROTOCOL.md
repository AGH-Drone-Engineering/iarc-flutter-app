# IARC 2026 — Layer 2 Mission Protocol

**Status:** v1. Implemented on both sides over UDP; LoRaCom is wired on the
ground station only.

Application-level protocol between the ground station and the drones' Raspberry Pi
companion computers. Messages travel inside the `PAYLOAD` of a LoRaCom `SENDMSG` /
`GETMSG` frame (`RPi_CM_Drone_Board/firmware_CMDB/loracom/protocol.adoc`), which the
firmware forwards verbatim.

## 1. Transports

The message set is identical on both; only framing and addressing differ.

|             | LoRaCom                                                   | UDP                             |
| ----------- | --------------------------------------------------------- | ------------------------------- |
| Path        | phone → USB → ESP → LoRa → HAT → UART → Pi                | phone → Wi-Fi → Pi              |
| Framing     | `TYPE\|ID\|LEN\|PAYLOAD\|CRC16` (`loracom/protocol.adoc`) | one message per datagram        |
| Drone id    | frame `ID` byte                                           | source/destination address      |
| Delivery    | host-polled via `GETMSG`                                  | pushed                          |
| Max payload | 248 bytes                                                 | datagram limit, keep under 1400 |

**UDP.** Each drone listens on an agreed port (default `14660`) and replies to the
source address and port of the datagram it received, so the ground station needs no
fixed address. The ground station identifies a drone by source address, so one
address per drone. `0xFF` broadcast is realised by sending to every configured
endpoint in turn.

The 248-byte cap and the `0x00`/`0x0A`/`0x0D` ban in apply on both transports, so a
message built for one is always valid on the other.

## 2. Encoding

| Rule               | Value                                                  |
| ------------------ | ------------------------------------------------------ |
| Character encoding | UTF-8                                                  |
| Format             | Compact JSON object, no insignificant whitespace       |
| Max payload        | 248 bytes (LoRaCom `MAX_MESSAGE_SIZE`)                 |
| Forbidden bytes    | `0x00`, `0x0A`, `0x0D` anywhere in the payload         |
| Numbers            | Decimal text, no exponent notation (`1e-5` is invalid) |
| lat / lon          | 7 decimal places; trailing zeros MAY be trimmed        |
| alt / dist / speed | 1–2 decimal places, metres                             |
| Unknown fields     | MUST be ignored                                        |
| Unknown `t`        | MUST be answered with `NACK` / `UNSUPPORTED`           |

## 3. Envelope

Every message is a flat JSON object with three mandatory fields; type-specific fields
sit alongside them at the top level.

| Field | Type   | Meaning                                                                               |
| ----- | ------ | ------------------------------------------------------------------------------------- |
| `v`   | int    | Protocol version, currently `1`. A mismatch MUST be answered with `NACK`/`BAD_PARAM`. |
| `q`   | int    | Sequence number, `0..65535`, wrapping. Unique per sender per power cycle.             |
| `t`   | string | Message type, uppercase.                                                              |

## 4. Addressing

Layer 2 never carries a drone ID; it comes from the transport

|                 | Value                                                 |
| --------------- | ----------------------------------------------------- |
| Drone addresses | `1..31` (HAT jumper range; also the UDP endpoint key) |
| Broadcast       | `0xFF`                                                |
| Reserved        | `0x00`                                                |

## 5. Ground → drone

### `START_DEMO`

```json
{ "v": 1, "q": 1, "t": "START_DEMO", "alt": 3.0 }
```

| Field | Type  | Notes                                     |
| ----- | ----- | ----------------------------------------- |
| `alt` | float | Hover altitude AGL, metres, `0.5 .. 30.0` |

Arm, take off to `alt`, hold position, await `MOVE` / `LAND`. The `ACK` carries
the drone's position, which anchors the demo — see §6.

### `START_MAIN`

```json
{
  "v": 1,
  "q": 2,
  "t": "START_MAIN",
  "c": [
    [50.062975, 19.9157],
    [50.062983, 19.915846],
    [50.063157, 19.915882],
    [50.0632, 19.91577]
  ],
  "alt": 8.0
}
```

| Field | Type  | Notes                                                  |
| ----- | ----- | ------------------------------------------------------ |
| `c`   | array | Exactly 4 corners, each `[lat, lon]` — latitude first  |
| `alt` | float | Search altitude AGL, metres, `0.5 .. 30.0`             |

Corner order is not significant; both ends normalise to a counter-clockwise loop.

### `MOVE`

```json
{ "v": 1, "q": 3, "t": "MOVE", "to": [50.062975, 19.9157] }
```

| Field | Type  | Notes                                       |
| ----- | ----- | ------------------------------------------- |
| `to`  | array | Target `[lat, lon]` — latitude first        |

Fly to `to`, holding the altitude set by `START_DEMO`. Absolute coordinates, so
hops do not accumulate error and both ends agree on the frame without sharing an
origin.

Arrival is reported with `EVT`/`WAYPOINT_REACHED`. Valid only in demo mode,
otherwise `NACK`/`BAD_STATE`; a target outside the geo-cage is `NACK`/`GEOFENCE`.

### `LAND`

```json
{ "v": 1, "q": 4, "t": "LAND" }
```

Descend and disarm at the current position.

### `RTH`

```json
{ "v": 1, "q": 5, "t": "RTH" }
```

Return to the launch point at the drone's assigned RTH altitude and land. The altitude
is keyed off the drone's own number and is not a parameter.

### `STATUS`

```json
{ "v": 1, "q": 7, "t": "STATUS" }
```

Reply with `ACK`, then a `TELEM`.

### Out of scope: the killswitch

Cutting motors is a hardware function of the IARC HAT — the ESP32-S3 drives
`KILLSWITCH_FC_CTL` / `KILLSWITCH_PSU_CTL` directly
(`RPi_CM_Drone_Board/firmware_IARC_HAT/src/node/main.cpp`). It deliberately does
not travel as a Layer 2 message, and this protocol MUST NOT grow one.

The reason is the failure mode a killswitch exists for. Everything in this
document is decoded on the Pi by a mission process: a kill carried here works
only while the companion computer has booted, the mission process is alive and
the JSON codec is reachable. Those are exactly the conditions under which you
need to cut motors. A path that shares a failure domain with the thing it is
meant to stop is not a killswitch.

`TELEM`'s `KILLED` state still reports the outcome — the drone says its motors
are cut regardless of what cut them.

## 6. Drone → ground

### `ACK`

```json
{ "v": 1, "q": 10, "t": "ACK", "re": 2, "lat": 50.062975, "lon": 19.9157 }
```

| Field        | Type  | Notes                                            |
| ------------ | ----- | ------------------------------------------------ |
| `re`         | int   | The `q` being acknowledged                       |
| `lat`, `lon` | float | Position when the command was accepted. Optional. |

Means received and accepted, not completed. Completion is reported via `EVT`.

`lat`/`lon` are sent whenever the drone has a fix. They cost nothing extra on
the wire and make every acknowledgement a position fix, which is what lets a
`START_DEMO` `ACK` double as the demo's anchor.

### `NACK`

```json
{ "v": 1, "q": 11, "t": "NACK", "re": 2, "err": "NO_GPS" }
```

| Field | Type   | Notes                  |
| ----- | ------ | ---------------------- |
| `re`  | int    | The `q` being rejected |
| `err` | string | See below              |

| `err`         | Meaning                                              |
| ------------- | ---------------------------------------------------- |
| `NO_GPS`      | No GPS fix, or fix too poor to arm                   |
| `NOT_ARMED`   | Flight controller refused to arm                     |
| `BUSY`        | A mission is already running                         |
| `BAD_STATE`   | Command invalid in the current mission state         |
| `BAD_PARAM`   | Malformed or out-of-range parameter, or `v` mismatch |
| `GEOFENCE`    | Requested position violates the geo-cage             |
| `LOW_BATT`    | Battery below the mission threshold                  |
| `UNSUPPORTED` | Unknown message type                                 |

### `TELEM`

```json
{
  "v": 1,
  "q": 12,
  "t": "TELEM",
  "lat": 50.062975,
  "lon": 19.9157,
  "alt": 8.2,
  "bat": 14.8,
  "pct": 87,
  "st": "MAIN",
  "vel": [1.23, -0.45],
  "acc": 0.85,
  "ts": 412350
}
```

| Field        | Type   | Notes                          |
| ------------ | ------ | ------------------------------ |
| `lat`, `lon` | float  | Current position, WGS84                      |
| `alt`        | float  | Altitude AGL, metres                         |
| `bat`        | float  | Pack voltage, volts. Optional.               |
| `pct`        | int    | Battery remaining, `0..100`. Optional.       |
| `st`         | string | See below                                    |
| `vel`        | float[2] | Ground velocity `[north, east]`, m/s. Optional. |
| `acc`        | float  | Horizontal position accuracy, metres. Optional. |
| `ts`         | int    | Sample time, see below. Optional.            |

#### `vel` — ground velocity

The EKF's own velocity estimate, north/east in m/s, taken from the same
`GLOBAL_POSITION_INT` as the position — so it costs the drone nothing to read
and 21 bytes to send.

It is there so the ground station does not have to infer motion by differencing
1 Hz positions, which is half a sample behind, noisy at the scale of GPS jitter,
and reads zero whenever two fixes land on the same spot. Anything predicting
where drones will be — collision checks, arrival detection — should prefer it.

On an airframe with optical flow fused (`EK3_SRC1_VELXY = 5`) this is the most
accurate number the vehicle produces, good to a few cm/s. Note that flow
improves *velocity* and short-term drift; absolute latitude and longitude stay
GPS-anchored, so `vel` being excellent does not mean the position is.

#### `acc` — how good the fix is

The GPS receiver's own 1-sigma horizontal accuracy, in metres
(`GPS_RAW_INT.h_acc`). Omitted when the receiver does not report one, and
"omitted" means *unknown*, not *perfect*.

Read this as an upper bound on the error in `lat`/`lon`, not a measurement of
it. It is taken **before** the EKF fuses IMU and optical flow, so the position
actually reported is normally better than `acc` claims. The number that would
say how much better is the filter's own 1-sigma from its state covariance
(`AP_AHRS::get_pos_vel_uncertainty`), and it is not obtainable: ArduPilot sends
neither `ESTIMATOR_STATUS` (which carries `pos_horiz_accuracy` in metres) nor
`GLOBAL_POSITION_INT_COV`; the variances in `EKF_STATUS_REPORT` are
dimensionless innovation test ratios; and it is not exposed to Lua scripting, so
no onboard script can republish it. Getting it would take a firmware change.

Being pessimistic is the right failure direction for anything sizing a
separation bubble, which is what the ground station uses it for.

#### `ts` — when the position was taken

Milliseconds on the drone's own monotonic clock, recorded when it **read** the
position from the flight controller — not when the frame was built, and not a
wall clock.

It is deliberately not calendar time. A Pi in the field has no RTC and no
network, so its clock is whatever it booted with; in testing the drone and the
phone have been seven hours apart. Comparing an absolute drone timestamp to
phone time would produce confident nonsense.

What the ground station can do with it is work out **age**. For each frame,
`received_at - ts` is the (unknown, constant) clock offset plus however long
that frame waited on the radio. Queue delay is never negative, so the smallest
value seen so far is the best estimate of the pure offset; anything above it is
that frame's transit delay.

This matters because arrival time lies on a polled link: a frame can sit in the
ESP's queue for seconds, so a position that arrives "just now" may describe
where the drone was several seconds ago. Any ground-station logic that keeps
drones apart by position has to be able to tell those cases apart.

A drone that restarts sends `ts` backwards. A drop of more than ~30 s is a
restart (start the estimate again); anything smaller is an out-of-order frame
and must still be aged, not discarded.

Adds 12 bytes: a TELEM goes from ~82 to ~94 bytes, against a 248-byte cap and a
238-byte single-frame limit, so it neither fragments nor costs an extra frame.

| `st`      | Meaning                              |
| --------- | ------------------------------------ |
| `BOOT`    | Booting, not ready                   |
| `IDLE`    | Ready, awaiting a start command      |
| `ARMING`  | Arming                               |
| `TAKEOFF` | Climbing to target altitude          |
| `HOVER`   | Holding position, awaiting a command |
| `DEMO`    | Executing a demo `MOVE`              |
| `MAIN`    | Running the field mission            |
| `RTH`     | Returning to home                    |
| `LANDING` | Descending                           |
| `LANDED`  | On the ground, disarmed              |
| `ERROR`   | Faulted                              |
| `KILLED`  | Motors cut by the hardware killswitch |

Send both battery fields when known: `bat` is the raw truth and always
available, `pct` is what an operator can act on but needs a configured pack
capacity. Voltage sags under load, so judge charge on `pct` where there is one.

Sent every 1000 ms while airborne, every 5000 ms while `IDLE` / `LANDED`, by
default. **The rate is an operator setting and may be anything, including
zero — no `TELEM` at all.**

`TELEM` is therefore **advisory**: it is what puts a moving dot on the operator's
map, and nothing in a mission may be gated on it. A demo sequence advances on
`ARRIVED`, which is acknowledged and retried; a ground station that instead
inferred arrival from a `TELEM` state change would stop working the moment the
rate was turned down, and would be inferring it from a stream that can drop
frames silently in any case.

The reason the knob exists: on a link four drones share, `TELEM` at 1 Hz is over
half of all traffic, and the mission needs about two frames per leg rather than
five or six. Turning it off costs the operator sight of the drones between
vertices, and costs the mission nothing.

Consumers must not read silence as failure. A ground station that lands a drone
for going quiet has to derive that limit from the configured rate, or drop the
check and bound the thing that actually has to happen — a step completing.

### `MINE`

```json
{ "v": 1, "q": 13, "t": "MINE", "tag": 7, "lat": 50.062975, "lon": 19.9157 }
```

| Field        | Type  | Notes                  |
| ------------ | ----- | ---------------------- |
| `tag`        | int   | AprilTag ID            |
| `lat`, `lon` | float | Computed mine position |

Sent once per newly detected mine; the drone SHOULD de-duplicate by tag.

The ground station does **not** treat `tag` as identity — the same tag reported
at two distinct positions becomes two mines. A tag may be stuck on two mines, or
misread; dropping one is worse than showing both.

### `SCAN`

```json
{
  "v": 1,
  "q": 15,
  "t": "SCAN",
  "a": [50.062975, 19.9157],
  "b": [50.063157, 19.915882]
}
```

| Field    | Type  | Notes                                                                          |
| -------- | ----- | ------------------------------------------------------------------------------ |
| `a`, `b` | array | Two opposite corners, each `[lat, lon]` — latitude first. Order is irrelevant. |

Reports a lat/lon-aligned rectangle the drone has **processed** — one per
analysed frame. It does not claim the rectangle is empty: mines found inside it
are reported separately via `MINE`.

Sent immediately as each frame is processed, never batched — a mission emits
many, and an `RTH` or a lost link must not cost the coverage already earned. The
ground station accumulates them, so overlapping or repeated rectangles are
harmless and a drone need not track what it has already sent.

This is what lets the ground station tell _"no mine here"_ apart from _"nobody
looked here"_. Terrain covered by no `SCAN` is treated as **mined** when planning
the path — an unprocessed square is indistinguishable from a dangerous one, and
the route must not cross it.

A drone that never sends `SCAN` remains fully supported: the ground station
reports zero coverage and declines to plan a route, rather than planning one
across unverified ground.

### `ARRIVED`

```json
{
  "v": 1,
  "q": 42,
  "t": "ARRIVED",
  "to": [50.063157, 19.915882],
  "at": [50.063155, 19.915879],
  "spd": 0.12
}
```

| Field | Type     | Notes                                                                  |
| ----- | -------- | ---------------------------------------------------------------------- |
| `to`  | float[2] | The `MOVE`'s `to`, echoed back — latitude first. **Required.**          |
| `at`  | float[2] | Where the drone actually stopped.                                      |
| `spd` | float    | Ground speed when it declared arrival, m/s. Optional.                  |

The drone has stopped on the point it was sent to. This is the **only** message
that advances a demo sequence, so it is a report (§7) and not an `EVT`: it is
retried until acknowledged, because a lost arrival is a formation that never
takes another step.

`to` is what makes the report self-identifying, and it is required for a reason.
The ground station commands one vertex at a time, so an arrival whose `to` is
not the step currently in flight is an arrival somewhere nobody asked for — a
report delayed on the link, or a drone acting on a stale order — and it must not
release a barrier. Position alone cannot establish this: on any figure tight
enough to be worth flying, neighbouring vertices sit inside the arrival
tolerance of one another.

`at` and `spd` are there so the ground station can check the claim rather than
take it. A drone must not send `ARRIVED` while still moving: report it once the
vehicle has settled, not the moment the target radius is entered.

`ARRIVED` is also sent once after takeoff, with `to` set to the anchor, so the
opening barrier of a demo rests on the same acknowledged message as every later
step rather than on `EVT`/`MISSION_START`.

### `EVT`

```json
{ "v": 1, "q": 14, "t": "EVT", "ev": "MISSION_DONE" }
```

| `ev`               | Meaning                                                |
| ------------------ | ------------------------------------------------------ |
| `MISSION_START`    | Mission accepted and begun                             |
| `WAYPOINT_REACHED` | Waypoint reached (`MAIN`) or `MOVE` completed (`DEMO`) |
| `MISSION_DONE`     | Search pattern complete                                |
| `RTH_START`        | RTH begun                                              |
| `LANDED`           | On the ground, disarmed                                |
| `ABORT`            | Mission aborted                                        |

## 7. Reliability

### Command ACK

1. Every ground→drone command carries a unique `q`.
2. The drone MUST reply `ACK` or `NACK` with `re` = that `q`.
3. The ground station times out after 2000 ms and retries, 3 attempts total.
4. Retries reuse the original `q`.
5. After the final expiry the command is reported to the operator as unacknowledged.

Broadcast commands are tracked per drone: each drone ACKs individually.

### Report ACK (`MINE`, `SCAN`, `ARRIVED`)

Reports travel the other way and nothing repeats them. `TELEM` can be lost
harmlessly because another one follows — when the rate is not zero — but a lost
`MINE` is a mine nobody ever hears about again, a lost `SCAN` is ground the
planner must keep treating as unsearched, and a lost `ARRIVED` is a formation
that never takes another step. So these three are acknowledged in the reverse
direction:

1. The drone sends `MINE` / `SCAN` / `ARRIVED` with a unique `q` and keeps it
   queued.
2. The ground station MUST reply `ACK` with `re` = that `q`. It is an
   acknowledgement of *receipt*, not of anything the operator did with it.
3. The drone resends until acknowledged, backing off 2.5 s → 5 → 10 → 20 → 30 s
   and then every 30 s. There is no attempt limit: an unreported mine is worse
   than a busy radio.
4. Retries reuse the original `q`, so the ground station can tell a repeat from
   a second report.
5. The ground station MUST answer a repeat with a fresh `ACK` — if it stays
   silent because it already recorded that report, the drone retries for ever —
   and MUST NOT act on it twice. For `ARRIVED` that second point is not
   bookkeeping: acting on a repeat would release the same barrier twice and step
   the formation a vertex further than any drone has flown.
6. Nothing else is acknowledged this way. `TELEM` and `EVT` stay fire-and-forget.

A drone that cannot deliver a report keeps it across the rest of the flight; the
queue is bounded, and on overflow `SCAN` is dropped before `MINE`.

#### Implicit acknowledgement of `ARRIVED`

A silent `ARRIVED` is ambiguous from the drone's side: either the report did not
arrive, or it did and the `ACK` was lost coming back. One case has an answer.

A `MOVE` the drone has **not seen before** proves the ground station processed
the arrival — it commands one vertex at a time and only steps a drone it has seen
arrive, so the next step could not exist otherwise. On accepting such a `MOVE`
the drone MUST retire any queued `ARRIVED` and stop resending it.

"Not seen before" is exactly the §7 retransmission test: a repeated `q` is
answered from the reply cache and never reaches the accept path, so it cannot
retire anything.

### Polling (LoRaCom only)

LoRaCom is host-initiated; the board never pushes. The ground station:

- issues `GETMSG` every 200 ms while connected, and again immediately whenever a poll
  returned a message;
- MUST answer a `GETMSG` reply with a LoRaCom `ACK`, or the board resends the same
  message indefinitely;
- keeps at most one LoRaCom transaction in flight.

### Sequence numbers

- `q` increments per message per sender and wraps at 65535.
- Receivers MUST NOT assume `q` arrives in order or without gaps.
- A repeated `q` from the same sender within 5 s **of the last time that `q` was
  seen** MUST be treated as a retransmission: re-send the cached reply, do not
  repeat the action, and restart the 5 s from this repeat.

  Measuring the window from the *first* reply instead caps protection at a fixed
  5 s no matter how many retries arrive — with a 2 s retry interval the third
  retransmission lands outside it and the command executes a second time. The
  window must last as long as the sender keeps asking.

- Consequently a sender's retry interval MUST be shorter than 5 s. A retry that
  arrives after the window has lapsed is not a retransmission, it is a new
  command carrying an old order, and the receiver cannot tell the difference.

## 8. Demo sequencing

The ground station holds the choreography and issues it one waypoint at a time.
The drone flies where it is told and reports arrival; it stores no routine.

```
START_DEMO ──ACK(lat,lon)──► ARRIVED(anchor) ──► MOVE ──ACK──► ARRIVED(to,at) ──► MOVE ──► …
                               │                   │             │
                            no ACK               NACK      to ≠ live step
                               │                   │             │
                               └────── RTH ────────┘          LAND
```

1. `START_DEMO` arms the drone and takes it to `alt`. Its `ACK` carries the
   drone's position — the anchor the ground station lays the figure around.
2. Once airborne and holding over that anchor the drone sends `ARRIVED` with
   `to` = the anchor. That opens the sequence.
3. On `ARRIVED` — and on nothing else — the ground station sends the next `MOVE`.
   `EVT`/`WAYPOINT_REACHED` is still sent for the operator, but it is not a gate:
   it is unacknowledged, carries no position, and names no waypoint.
4. Before advancing, the ground station MUST check the report against the step it
   is waiting on: `to` must match the `MOVE` currently in flight, and `at` must
   be within its arrival tolerance of it. Either failing means the drone is not
   where the formation's geometry says it is, and it is landed rather than
   advanced.
5. A `MOVE` the ground station has superseded MUST NOT be retried. Once a drone
   has been seen to arrive at vertex *k*, the outstanding `MOVE` for *k* has done
   its job whether or not its `ACK` came back; retrying it later reuses the
   original `q`, which outside the retransmission window is a fresh order to fly
   back to a vertex the formation has left.
6. If a command is never acknowledged (§7, attempts exhausted) **or** is answered
   with `NACK`, the ground station stops advancing that drone's sequence and
   brings it down.
7. `EVT`/`MISSION_DONE` or `EVT`/`LANDED` ends the sequence normally.

None of this depends on `TELEM`, which may be off entirely.

Each drone runs its own sequence and is advanced independently.

The ground station bounds the sequence at 200 steps as a runaway guard; a drone
that has not reported `MISSION_DONE` by then is sent `RTH`.

## 9. Example exchange (LoRaCom)

```
Phone → ESP   SENDMSG id=3  {"v":1,"q":1,"t":"START_DEMO","alt":3.0}
ESP  → Phone  ACK

Phone → ESP   GETMSG
ESP  → Phone  ACK                                     (queue empty)

Phone → ESP   GETMSG
ESP  → Phone  GETMSG id=3     {"v":1,"q":40,"t":"ACK","re":1,"lat":50.062975,"lon":19.9157}
Phone → ESP   ACK                                     (pops the queue)

Phone → ESP   GETMSG
ESP  → Phone  GETMSG id=3     {"v":1,"q":41,"t":"TELEM","lat":50.062975,"lon":19.9157,"alt":3.1,"bat":15.6,"st":"HOVER"}
Phone → ESP   ACK
```
