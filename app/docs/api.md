# API reference

Base URL: http://localhost:3001/api. POST uses application/json.
The body limit is 2 MB. When APP_USERNAME and APP_PASSWORD are both set, all
data routes require `Authorization: Bearer <token>`. POST /auth/login accepts
`{"username":"...","password":"..."}` and returns a token valid for eight
hours or until API restart/logout. POST /auth/logout revokes it; GET /auth/status
reports whether login is configured. This is a single-user bench account.
Text is trimmed server-side. Device names/serials are limited to 100 characters, session
names to 120, and notes to 2,000.

| Method | Route | Purpose |
| --- | --- | --- |
| GET | /devices | List registered devices |
| POST | /devices | Create from deviceName and unique serialNumber |
| GET | /sessions | List newest-first sessions |
| POST | /sessions | Create from deviceId, sessionName, startTime, optional notes |
| GET | /sessions/:id | Metadata and saved measurement rows |
| POST | /sessions/:id/measurements | Upload complete measurement samples |
| GET | /test-input | Latest transient device frame, or null before publication |
| POST | /test-input | Validate and publish a transient frame; no SQL writes |
| GET | /device-input | Latest CRC-validated ESP32 UDP frame and receiver status |
| GET | /device-sources | Discovered UDP senders, live/offline state, paired device ID |
| POST | /device-sources/pair | Pair a currently live sender from `{ "sourceIp": "..." }` |
| GET | /simulation | Demo only: sender counters, receiver metrics, and active scenario |
| POST | /simulation | Demo only: choose `{ "scenario": "baseline" }` |

The UDP listener is enabled with `DEVICE_UDP_ENABLED=1` or `DEVICE_IP`; the latter
restricts reception to one source. `DEVICE_UDP_PORT` overrides the default.
It accepts protocol-v1 88-byte measurement frames or 1–10-frame batch datagrams
from discovered IPv4 senders, subject to the optional source filter.
`/device-input` exposes only the newest valid
frame; pass `?sourceIp=<IPv4>` to read a selected sender. It does not queue all
frames or write measurements. Its `recordedAt` is
the API laptop's receive time, while `timestampUs` is the MCU's monotonic time.
See [device connection](device-connection.md) for setup and limits.

Receiver metrics include `receivedFrames` (valid decoded frames), `uniqueFrames`
(accepted forward/restart frames), `missingFrames` (forward sequence gaps),
`duplicateFrames`, `lateFrames`, `restartEstimates`, `invalidFrames`,
`invalidDatagrams`, `crcErrors`, `framesPerSecond` (rolling last second), and
`lastReceivedAt`. `stale` becomes true after five seconds without a new valid
frame. `lossPercent` is gaps divided by accepted frames plus gaps; it is an
estimate, including gaps caused by corruption. Late arrivals do not undo gaps.
Counters reset on API restart or source eviction from the 32-source cache.

Simulation routes are enabled by `NETWORK_SIMULATION_ENABLED=1` in the normal
API and are also available in the optional sandbox. They require the same
bearer login and accept `stopped`, `baseline`, `load`, `loss`,
`corrupt`, or `outage`. Reports include the selected target rate, generated and
sent counts, intentional drop/corruption counts, scheduler skips, socket errors,
receiver sources, storage mode, and report timestamp. Invalid scenarios return
400. Scenario changes retain counters and sequence numbers.

GET /health is outside /api. It reports service=capstone, status, and storage
(postgres or memory). PostgreSQL mode checks a query and returns 503 if unavailable.

## Manual device publication

### Buffered UDP capture

`GET /device-frames?sourceIp=127.0.0.1&cursorMode=arrival` establishes a baseline
without returning historical frames. It returns `streamId` and `nextCursor`.
Pass those as `streamId` and `afterCursor` on subsequent requests. `limit` is
1–1,000. Each response advances only through the returned page, reports
`hasMore`, and counts frames no longer retained as `missedFrames`. Retention is
60,000 frames per source. `streamReset` means a receiver/source was recreated;
stop capture and establish a fresh baseline. Firmware sequence resets do not
reset arrival cursors. Legacy `afterSequence` paging is retained for compatibility.

`recordedAt` is an estimated, strictly increasing microsecond sample time,
anchored once per estimated boot to host UTC using the MCU's relative clock;
`receivedAt` is actual arrival time. The collector preserves recordedAt on retry.
`GET /sessions/:id?recent=1` returns at most the latest 16,000 measurement rows,
with `measurementCount` and `truncated`; time filters apply before this limit.
Without `recent=1`, the endpoint retains its full-history contract.

POST /test-input:

```json
{"channels":[1.234,-0.5,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}
```

Response: 201 with frameId (UUID), recordedAt (UTC timestamp), and channels.
This does not create a device, session, or measurement in Postgres. GET returns
the same frame until another publication or API restart. Start the mobile
collector before publishing a frame you want recorded.

## Session creation

POST /sessions:

```json
{
  "deviceId": "existing-device-uuid",
  "sessionName": "Bench test",
  "startTime": "2026-09-13T12:00:00.000Z",
  "notes": "Manual test; no hardware connected"
}
```

The mobile app registers/reuses serial MANUAL-001, then calls this route when
Create session is pressed. Multiple simultaneous collectors creating that
device for the first time may encounter the unique-serial constraint.

## Collector upload

POST /sessions/:id/measurements:

```json
{
  "samples": [{
    "recordedAt": "2026-09-13T12:00:01.000Z",
    "channels": [1.234,-0.5,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
  }]
}
```

Success: 201 with {"insertedMeasurements":16}. Postgres counts processed rows,
including existing keys updated during retry. Exactly 16 finite numeric voltages
in [-5,+5] are required. The samples array must contain 1–1,000 items. Every
timestamp must be a real calendar time, include an explicit timezone, and use no
more than microsecond precision (six fractional digits); it is normalized to UTC without
truncating sub-millisecond intervals. Preserve timestamps
on retry.

## Web readback

GET /sessions/:id returns sessionId, deviceId, deviceName, serialNumber,
sessionName, startTime, endTime, notes, and measurements. A measurement is:

```json
{"recordedAt":"2026-09-13T12:00:01.000Z","channel":0,"voltage":1.234}
```

Session-list from/to filters apply to session startTime. Detail from/to filters
apply to measurement recordedAt, inclusive. The web UI exposes From/To UTC fields.
Accepted format: YYYY-MM-DDTHH:mm:ssZ with optional 1–6 fractional-second digits.
PostgreSQL readback emits ISO text with six fractional digits, preserving distinct
frames within the same millisecond. Batch uploads may complete out of order;
session endTime remains the precise maximum committed sample time.
Invalid calendar dates, missing UTC timezone, and reversed ranges return 400.
Leave a boundary out for an open-ended range; omit both for full history.
Pagination remains future work.

## Errors and database structure

Errors use {"error":"description"}. Malformed JSON and validation failures
return 400, unknown routes/missing sessions return 404, uniqueness conflicts
return 409, and request bodies above 2 MB return 413. Unexpected failures return
500 with a generic message; internal database details are logged server-side and
are not exposed to clients. Never report a failed response as saved.

monitor_device.device_id -> test_session.device_id
test_session.session_id -> measurement.session_id

Devices and sessions have UUID primary keys. Measurements have a generated
integer key and a unique session/time/channel constraint. SQL also checks channel
and voltage ranges and indexes session/time. Queries are parameterized; SQL
aliases convert snake_case columns to camelCase API names. Read schema.sql for
the executable definition and postgres-store.js for transactions.
