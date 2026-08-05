# IARC 2026 — Layer 2 Mission Protocol

**Status:** DRAFT v1. Not yet implemented on the Pi or ESP side.

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
| lat / lon          | ≥ 7 decimal places                                     |
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

Arm, take off to `alt`, hold position, await `MOVE` / `LAND`.

### `NEXT_STEP`

```json
{ "v": 1, "q": 8, "t": "NEXT_STEP" }
```

Advance the demo routine by one step. Valid only in demo mode, otherwise
`NACK`/`BAD_STATE`.

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

| Field | Type  | Notes                                                 |
| ----- | ----- | ----------------------------------------------------- |
| `c`   | array | Exactly 4 corners, each `[lat, lon]` — latitude first |
| `alt` | float | Search altitude AGL, metres                           |

Corner order is not significant; both ends normalise to a counter-clockwise loop.

### `MOVE`

```json
{ "v": 1, "q": 3, "t": "MOVE", "dir": "FORWARD", "d": 3.0 }
```

| Field | Type   | Notes                           |
| ----- | ------ | ------------------------------- |
| `dir` | string | See below                       |
| `d`   | float  | Distance, metres, `0.5 .. 20.0` |

`dir` is one of, matching `demo_mission.commands.Command`:

```
FORWARD  BACK  LEFT  RIGHT  FORWARD_RIGHT  BACK_RIGHT  BACK_LEFT  FORWARD_LEFT
```

Relative to the drone's body frame. Valid only in demo mode, otherwise
`NACK`/`BAD_STATE`.

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

### `KILL`

```json
{ "v": 1, "q": 6, "t": "KILL", "k": "BE11DEAD" }
```

| Field | Type   | Notes                                                  |
| ----- | ------ | ------------------------------------------------------ |
| `k`   | string | Exactly `"BE11DEAD"`. Any other value MUST be ignored. |

Sent unicast per drone, 3 times, 300 ms apart, regardless of ACK. The drone MUST act on
it even when it cannot reply.

### `STATUS`

```json
{ "v": 1, "q": 7, "t": "STATUS" }
```

Reply with `ACK`, then a `TELEM`.

## 6. Drone → ground

### `ACK`

```json
{ "v": 1, "q": 10, "t": "ACK", "re": 2 }
```

| Field | Type | Notes                      |
| ----- | ---- | -------------------------- |
| `re`  | int  | The `q` being acknowledged |

Means received and accepted, not completed. Completion is reported via `EVT`.

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
  "st": "MAIN"
}
```

| Field        | Type   | Notes                          |
| ------------ | ------ | ------------------------------ |
| `lat`, `lon` | float  | Current position, WGS84        |
| `alt`        | float  | Altitude AGL, metres           |
| `bat`        | float  | Pack voltage, volts. Optional. |
| `st`         | string | See below                      |

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
| `KILLED`  | Motors cut by `KILL`                 |

Sent every 1000 ms while airborne, every 5000 ms while `IDLE` / `LANDED`.

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

Reports a lat/lon-aligned rectangle the drone considers **swept**: every mine
inside it has already been reported via `MINE`, so the rest of the rectangle is
clear.

Sent whenever a region completes; a mission emits many. The ground station
accumulates them, so overlapping or repeated rectangles are harmless and a drone
need not track what it has already sent.

This is what lets the ground station tell _"no mine here"_ apart from _"nobody
looked here"_. Terrain covered by no `SCAN` is treated as **mined** when planning
the path — an unswept square is indistinguishable from a dangerous one, and the
route must not cross it.

A drone that never sends `SCAN` remains fully supported: the ground station
reports zero coverage and declines to plan a route, rather than planning one
across unverified ground.

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
- A repeated `q` from the same sender within 5 s MUST be treated as a retransmission:
  re-send the ACK, do not repeat the action.

## 8. Demo sequencing

The demo routine is driven by the ground station, one step per round trip. The
drone holds the choreography; the ground station only advances it and handles
failure.

```
START_DEMO ──ACK──► NEXT_STEP ──ACK──► NEXT_STEP ──ACK──► …
                        │                  │
                     no ACK              NACK
                        │                  │
                        └────── RTH ───────┘
```

1. After `START_DEMO` is acknowledged, the ground station sends `NEXT_STEP`.
2. Each `ACK` of a `NEXT_STEP` triggers the next `NEXT_STEP`.
3. If a command is never acknowledged (§7, 3 attempts exhausted) **or** is
   answered with `NACK`, the ground station sends `RTH` to that drone and stops
   advancing its sequence.
4. `EVT`/`MISSION_DONE` or `EVT`/`LANDED` ends the sequence normally.

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
ESP  → Phone  GETMSG id=3     {"v":1,"q":40,"t":"ACK","re":1}
Phone → ESP   ACK                                     (pops the queue)

Phone → ESP   GETMSG
ESP  → Phone  GETMSG id=3     {"v":1,"q":41,"t":"TELEM","lat":50.0629750,"lon":19.9157000,"alt":3.1,"bat":15.6,"st":"HOVER"}
Phone → ESP   ACK
```
