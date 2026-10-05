# Architecture and design decisions

## Responsibilities

| Component | Responsibility | Does it write measurements? |
| --- | --- | --- |
| Manual dashboard | Publish one complete device-input frame | No |
| Mobile collector | Receive, log, and upload new frames during capture | Yes, through API |
| Express/Node | Validate requests and mediate database access | Yes |
| PostgreSQL | Store devices, sessions, and per-channel measurements | Yes |
| Web viewer | Select sessions and display saved voltages | No |
| Network lab (isolated demo) | Select conditions for a real loopback UDP sender; show receiver counters | No |

All user interfaces are Flutter/Dart. Android and iOS use the mobile role.
The Flutter web build has a history screen and routes for the two testing
previews. Sharing code does not bypass the mobile-to-database boundary.

## A frame's lifecycle

1. The input dashboard submits 16 finite voltages to POST /api/test-input.
2. Express validates the values, timestamps the frame in UTC, and gives it a UUID.
   This frame stays in process memory and is replaced by the next publication.
3. Start capture records the current frame ID as a baseline. It only accepts
   subsequently published frames; an old frame cannot enter a new session.
4. The mobile app polls once a second. It displays the latest device input.
5. During capture, a new frame is saved to the local JSON log with its session
   and API destination. Only after that write succeeds can it be uploaded.
6. The app posts the saved timestamp/channels to the session measurement route.
7. PostgreSQL writes the 16 rows transactionally. The log marks them uploaded.
8. The web viewer polls the selected session and displays its latest rows.
   Optional inclusive UTC time filters apply at the API; the graph and latest
   values share those filtered rows. Choose CH 1 through CH 16 for the graph.
   The horizontal axis uses elapsed measurement time, not array positions.
   A single sample displays as a dot. Lines connect samples but do not imply
   that intermediate measurements were captured.

Stop capture stops accepting new samples, but already logged pending uploads
continue retrying. Capture state is not restored automatically after an app
restart; restart with Start capture explicitly. Saved pending uploads are loaded
and retried against their original API/session.

## Numbering and timestamps

Array index 0 = SQL channel 0 = displayed CH 1. Array index 15 = CH 16.
Every voltage must be between -5 and +5 V inclusive. A complete sample always has
16 values. UI validation is for convenience; server validation is authoritative.

The manual input endpoint supplies the timestamp, which the collector preserves.
A future hardware transport must define its own clock alignment and resolution.
endTime currently means the latest uploaded sample, not a formal session-close
event. The SQL session constraint disallows an end before the session start.

## Local durability and retries

CaptureLog contains no widgets. It receives storage callbacks, enabling restart
and failure tests without disk/network dependencies. On mobile, storage uses
path_provider and a temporary file followed by rename in the app documents
directory. The browser preview uses localStorage under capstone-capture-log-v1.

Entries retain apiUrl, sessionId, frameId, recordedAt, channels, and uploaded.
A failed upload stays pending. Switching API addresses does not redirect old
frames: only entries matching the connected URL are retried. Deleting a server
session or clearing a development database can leave an upload pending; restore
the session/database or deliberately manage that local log.

Postgres upserts the unique (session_id, recorded_at, channel) tuple. Retrying
with an unchanged timestamp is idempotent. A successful server response lost in
transit can therefore be retried safely. The memory adapter mirrors this
idempotency for tests but does not provide process-restart durability.

## Deliberate limits

Manual test input keeps only its latest publication. UDP device capture uses a
60,000-frame ring per sender and pages by arrival cursor, independently of the
one-second display refresh. Uploads use batches of up to 1,000 frames and bulk
SQL inserts. History charts read the latest 1,000 frames while reporting the full
stored count. The platform journal retains all pending frames (up to 60,000) and the last
500 uploaded frames. Long outages or sustained overload can exhaust the receiver
buffer; the collector reports missed buffered frames instead of hiding the gap.

Only one collector should capture a session at a time. Browser log storage is
shared per origin and is not a cross-tab database. A closed or suspended app
cannot keep polling. Background mobile acquisition requires explicit future
platform work.

## ESP32 bench integration

The laptop API can receive version-1 UDP measurements and ten-frame batches from
the ESP32, validate each frame's header and CRC, and expose the latest frame per
sender. A logged-in operator selects a discovered sender and pairs its IP-based
record before creating a session. The mobile collector reads the selected
sender's buffered frames, journals them, and uploads them to that session. Pairing is an
app-side selection; the current firmware does not authenticate itself.

An independent 250 ms collector pump reads up to eight 1,000-frame pages per
turn; up to four 1,000-frame upload requests run concurrently outside the local
commit lock. The screen refreshes once per second. A per-source arrival cursor advances
only after a page is logged locally. Unlike the firmware sequence, it survives
device sequence resets and wraparound. A receiver restart changes the stream ID
and stops capture until the operator starts again. The final buffered frames can
be drained even after the sender becomes stale.

Frames in a datagram no longer share a database timestamp: recordedAt is
reconstructed by anchoring the device clock once per estimated boot to host UTC,
with strictly increasing microsecond timestamps that retain intervals above 1 kHz.
receivedAt retains the actual datagram arrival time. These are estimated UTC
sample times, not synchronized device-clock measurements. Retries preserve them.
PostgreSQL inserts each batch in one statement. The local log retains all pending
frames (up to 60,000) plus 500 acknowledged frames; complete history lives in SQL.
The web chart fetches the latest 1,000 samples in its selected time range and
displays the full row count. No measurements are removed from the database.
Keep validation, local log, and upload contract stable when extending transport.
See the [capture next-steps guide](1ksps-capture.md) for sustained 2kSPS software
results, the 1kSPS minimum, shorter 3kSPS stress evidence and physical acceptance.
Randomized sensor sim-mode remains future work. The deterministic network lab
uses the UDP receive boundary with explicit scenarios and synthetic-data labels.
The graph already consumes stored sessions.

## Network demo design

`tools/demo.js` starts a separate loopback HTTP server and UDP receiver, with a
fixed bench login and a fresh MemoryStore. It never loads `.env`. Browser demo
logs include a run identifier so pending uploads from a discarded temporary
server are not replayed into a new one.

The default `Start_Capstone.cmd` runs the normal app with persistent local
PostgreSQL. It uses the configured bench login and enables the real device
listener. `NETWORK_SIMULATION_ENABLED=1` also exposes manually controlled
network scenarios through a dedicated loopback socket. The generator starts
stopped and never creates sessions or starts capture. The original `.env`
database remains available with `--configured-database`; local/cloud records
are separate. Launch readiness verifies storage location, features, and login.

The sender batches ten protocol-v1 frames per datagram. Scenarios generate
100 or 1,000 frames/s; loss drops every fifth packet, corruption damages one
frame in every tenth packet, and outage drops everything. Counters distinguish
intentional drops, generator scheduling skips, socket failures, and receiver
observations. The demo endpoints exist only when a simulator is injected.

The receiver tracks up to 32 source IPs, validates each frame independently,
and retains the latest accepted frame. Sequence arithmetic supports uint32 wrap.
Duplicates and late frames never replace a newer value. Forward gaps are
missing-frame estimates; late arrivals do not undo them. A low sequence plus
a backward boot timestamp can indicate a restart, but the protocol has no boot
identifier, so this remains an estimate. No valid new frame for five seconds
marks a source stale. The collector clears stale voltages but drains buffered
frames and retries saved uploads. A 401 response stops capture and requires login again.

This tests transport handling and app recovery. It does not simulate RF physics,
router queues, or physical-board performance. See the
[demo guide](network-demo.md) for the presentation and physical-bench boundary.

Production plan: Vercel serves the Flutter web build; AWS runs Express and
Postgres. Current data is local. Persistent user accounts, TLS deployment,
cloud resources, and cryptographic device identity remain required before
sharing it publicly.
