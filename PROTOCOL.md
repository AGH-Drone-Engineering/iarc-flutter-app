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

| Field | Type  | Notes                                                                        |
| ----- | ----- | ---------------------------------------------------------------------------- |
| `to`  | array | Target `[lat, lon]` — latitude first                                         |
| `alt` | float | Height for this hop, metres AGL. Optional — omit to fly it at the altitude `START_DEMO` set, which is every ordinary step. |

Fly to `to`. Absolute coordinates, so hops do not accumulate error and both ends
agree on the frame without sharing an origin.

`alt` is set only for a drone deliberately being flown off the rest — a joiner
catching up with a moving figure (§8). Unlike `RTH`, no ordering is required: a
joiner is on the same vertex index at both ends of the leg, so it keeps its anchor
spacing from everybody while it changes height.

Arrival is reported with `ARRIVED` (§6), which is what advances the sequence;
`EVT`/`WAYPOINT_REACHED` is also sent, for the operator. Valid only in demo mode,
otherwise `NACK`/`BAD_STATE`; a target outside the geo-cage is `NACK`/`GEOFENCE`.

### `LAND`

```json
{ "v": 1, "q": 4, "t": "LAND" }
```

Descend and disarm at the current position.

### `RTH`

```json
{ "v": 1, "q": 5, "t": "RTH", "alt": 2.0 }
```

| Field | Type  | Notes                                                                    |
| ----- | ----- | ------------------------------------------------------------------------ |
| `alt` | float | Height for the return, metres AGL. Optional — omit for the drone's own assigned RTH altitude, keyed off its number. |

Return to the launch point and land.

**With `alt`, the drone MUST reach that height in place before it translates.**
The ordering is the entire point. A single `go_to` changes position and height at
once, so the drone leaves on a diagonal and passes through whatever altitude the
rest of the formation is using, directly over their circles — which is why an
abort used to be `LAND` and never this. Separating vertically *first* removes that
objection; doing it at the same time does not.

The ground station picks the height so the return misses the formation — see §8.

### `STATUS`

```json
{ "v": 1, "q": 7, "t": "STATUS" }
```

Reply with a `TELEM`. Nothing else — there is no `ACK` (§7).

Sent only when the operator asks for it. It used to double as a keepalive on a
timer, which is what kept the drone's no-contact auto-land at bay; both are gone,
so this is now purely "tell me where you are, now".

### `PING`

```json
{ "v": 1, "q": 9, "t": "PING", "n": 1234 }
```

| Field | Type | Notes                                    |
| ----- | ---- | ---------------------------------------- |
| `n`   | int  | Ping counter, incrementing from 1        |

**Nothing answers a `PING` — not an `ACK`, not a `NACK`, not even
`UNSUPPORTED`.** It exists to measure the radio with the whole reliability layer
switched off, and any reply would add a transmission to the thing being measured.
A receiver that cannot act on it MUST drop it silently.

`n` counts pings independently of `q` because `q` wraps and is shared with every
other message the sender emits, whereas a gap in `n` is exactly one lost ping —
and the *shape* of the gaps is the diagnosis: isolated singles are collisions, a
run of a dozen is a fade or a full queue.

Answered by `PONG` (§6) on the receiver's own timer, not per ping.

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

**Retained in the codec, no longer sent.** The drones do not acknowledge
commands (§7); a ground station may still receive one from older firmware and
MUST treat it as nothing more than proof of contact.

The anchor a `START_DEMO` `ACK` used to carry now comes from the opening
`ARRIVED`, whose `to` is the anchor.

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
`ARRIVED`; a ground station that instead inferred arrival from a `TELEM` state
change would stop working the moment the
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
that advances a demo sequence, so it names its own step rather than
relying on order: `to` is echoed back, which an `EVT` could not do. Delivery is
the radio's business (§7).

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
opening barrier of a demo rests on the same self-identifying message as every
later step rather than on `EVT`/`MISSION_START`.

### `PONG`

```json
{ "v": 1, "q": 12, "t": "PONG", "rx": 480, "tx": 120, "last": 502 }
```

| Field  | Type | Notes                                        |
| ------ | ---- | -------------------------------------------- |
| `rx`   | int  | `PING`s this node has received               |
| `tx`   | int  | `PONG`s this node has now sent               |
| `last` | int  | `n` of the newest `PING` seen                |

Sent on a timer (once a second), **not** per `PING`, and acknowledged by nobody.

Those three counters against what the ground station tallied separate the two
directions, which a missing `ACK` can never do — an absent `ACK` cannot
distinguish "the command never arrived" from "the command arrived and its answer
was lost":

```
uplink loss   = 1 - rx / pings_sent
downlink loss = 1 - pongs_received / tx
```

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

**Delivery belongs to the LoRa layer. Nothing in this protocol retries, and
nothing in it is acknowledged.**

Every message is transmitted exactly once. The radio layer holds pending frames
in the ESP's own buffer and repeats them until they land; it knows within
milliseconds whether a frame was heard, which is a thing this layer could only
guess at after seconds.

### Why the acknowledgements were removed

They were counter-productive at both ends of the stack.

A retry from the ground station travels phone → USB → ESP → air and joins the
same four-slot outbound queue the original frame is already waiting in. Under
loss that offered *more* frames to a channel already dropping a third of them,
and the overflow was discarded silently. The same held on the drone.

Worse, an `ACK` is the least reliable message in the set: it is sent once and
never repeated, so it is the likeliest thing to be lost — and its loss used to be
read as the *command* having failed. On 2026-08-11 that landed three healthy
drones mid-figure, each still flying the formation correctly at the moment the
app gave up on it.

### How a sender learns a command was obeyed

From what the drone does, not from a receipt:

| Command | Evidence it was obeyed |
| --- | --- |
| `START_DEMO` / `START_MAIN` | `EVT MISSION_START`, the opening `ARRIVED`, or any airborne `TELEM` state |
| `MOVE` | `EVT WAYPOINT_REACHED`, then `ARRIVED` echoing the `to` it was given |
| `LAND` / `RTH` | `TELEM` reporting `LANDING`/`RTH`, then `EVT LANDED` |
| `STATUS` | the `TELEM` it provokes |

Every one of those repeats of its own accord, which is exactly what an `ACK`
never did. A drone that has gone quiet is detected by the *absence of all of
them*, not by one missing receipt.

### `NACK` stays

A `NACK` is not an acknowledgement — it is the only way a drone can say "I will
not do this", and it carries a reason (`NO_GPS`, `BAD_STATE`, `GEOFENCE`, …). It
says what will **not** happen, which no silence can. It is sent once, like
everything else, and the operator is shown it.

`BUSY` answering a start command is the exception that proves the rule: it means
the drone is already running a mission, which is agreement rather than refusal.

### Duplicate suppression

Retries are gone, so a repeated `q` can now only mean the radio delivered one
frame twice. Both ends still guard against it, because the cost is asymmetric:

- a repeated `MOVE` would step the formation a vertex past where any drone has
  flown;
- a repeated `ARRIVED` would release the same barrier twice;
- a repeated `MINE` would put the same mine on the map twice.

So a receiver MUST ignore a `q` it has already acted on (see §7 *Sequence
numbers*). It does **not** reply to the duplicate — there is nothing to reply
with.

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
- A repeated `q` from the same sender within 5 s of the last time that `q` was
  seen MUST be treated as a duplicate delivery: do not repeat the action, and do
  not reply. Restart the 5 s from this repeat.

  Nothing in this protocol retransmits, so a duplicate can only come from the
  radio layer delivering one frame twice — a rare event, and one the 5 s window
  covers with room to spare.

## 8. Demo sequencing

The ground station holds the choreography and issues it one waypoint at a time.
The drone flies where it is told and reports arrival; it stores no routine.

```
START_DEMO ──► ARRIVED(anchor) ──► MOVE ──► ARRIVED(to,at) ──► MOVE ──► …
                    │                          │
              nothing at all               to ≠ live step
                    │                          │
                    └─── drop from formation   └── LAND

The anchor comes from the opening `ARRIVED` -- its `to` IS the anchor -- not from
a `START_DEMO` receipt.
```

1. `START_DEMO` arms the drone and takes it to `alt`. Nothing is sent back
   immediately — the drone is busy arming and climbing, which can take half a
   minute.
2. Once airborne and holding over its takeoff point the drone sends `ARRIVED` with
   `to` = that point. **This is both "I am ready" and the anchor** the ground
   station lays the figure around, and it opens the sequence.
3. On `ARRIVED` — and on nothing else — the ground station sends the next `MOVE`.
   `EVT`/`WAYPOINT_REACHED` is still sent for the operator, but it is not a gate:
   it is unacknowledged, carries no position, and names no waypoint.
4. Before advancing, the ground station MUST check the report against the step it
   is waiting on: `to` must match the `MOVE` currently in flight, and `at` must
   be within its arrival tolerance of it. Either failing means the drone is not
   where the formation's geometry says it is, and it is landed rather than
   advanced.
5. Nothing retries a `MOVE`, so a superseded one cannot come back. This used to
   need saying: a retry reused the original `q`, and outside the duplicate window
   that was a fresh order to fly back to a vertex the formation had left.
6. A command answered with `NACK` stops that drone's sequence and brings it down —
   the drone has said it will not fly the step. **Silence does not.** A drone that
   simply stops reporting is dropped from the formation and left flying, for its
   pilot; see §7 for why a missing message is not evidence of a missing drone.
7. `EVT`/`MISSION_DONE` or `EVT`/`LANDED` ends the sequence normally.

### There are no timeouts

Neither end runs a clock. The ground station waits for `ARRIVED` and nothing else;
the drone waits for a command and nothing else. A lost report leaves the formation
hovering on its current vertex indefinitely, which is the safe way to be wrong and
undoes itself if the report turns up late.

Two things resolve the stall, and both are human:

- **Force the next step.** The operator can send the next vertex to the whole
  formation without waiting for every arrival. A drone that had not in fact
  arrived is then a vertex out of phase, and lockstep's separation guarantee is
  only true while every drone shares an index — so this is the operator's call to
  make with eyes on the aircraft, which is why it is a button and not a timer.
- **The pilots.** A drone landed manually reports `LANDING`/`IDLE`; the ground
  station drops it from the formation without commanding anything, and it rejoins
  on its next `START_DEMO` like any other drone.

The drone's own no-contact auto-land is off by default
(`--idle-timeout`, `demo_mission_with_app.py`). It used to be 30 s and relied on
the ground station's keepalives, which no longer exist: silence is now the normal
state of a formation waiting at a barrier, so that clock would end every muster.

`STATUS` is sent only when the operator asks for it. Nothing polls.

None of this depends on `TELEM`, which may be off entirely.

### Transit altitude

Two situations need one drone moved past a formation that is still flying: a
**stray** — an aircraft the ground station has no phase relationship with — and a
**joiner** catching up with a figure already in motion. Both are given a height one
metre clear of the formation, chosen the same way:

```
transit = A - 1   if A - 1 >= 1.0     // under it where there is room
          A + 1   otherwise           // no room under, go over
```

where `A` is the altitude the formation is flying. Under is preferred: it keeps the
drone out of the airspace above everybody else, a failure there falls less far, and
it stays clear of the 30 m ceiling.

| formation | transit |                                    |
| --------- | ------- | ---------------------------------- |
| 1.5 m     | 2.5 m   | over — 0.5 m is too low to transit |
| 2.0 m     | 1.0 m   | under                              |
| 3.0 m     | 2.0 m   | under                              |

**Stray:** `RTH` with `alt` = transit. The drone reaches that height in place, then
returns, then lands. It has no phase relationship with the figure, so horizontal
separation guarantees it nothing — the vertical split has to happen before it moves.

**Joiner:** `START_DEMO` with `alt` = transit, then every `MOVE` carries the same
`alt`. It walks the same vertex indices as the formation, one metre off, so it never
depends on horizontal separation while it is out of phase. The formation does not
stop for it.

**Merging** a joiner is simply dropping `alt` from its next ordinary `MOVE`. No
barrier and no pause: by then it is on the same vertex index as everyone, so it
holds its anchor spacing for the whole leg and may descend while translating.

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
