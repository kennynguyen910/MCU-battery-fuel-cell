# Requirements traceability

The current provisioning requirements come exclusively from
[Will and Kenny Startup.pdf](Will%20and%20Kenny%20Startup.pdf) and are mapped in
[BLE Wi-Fi provisioning v1](ble-wifi-provisioning-v1.md).
The matrix below records earlier, independent app functionality and does not
expand the provisioning v1 scope.

This matrix records the user-confirmed MVP requirements, where each requirement
is implemented, and how it can be accepted. The current demo includes responsive
cards, a consistent theme, explicit connection state, and step-based setup.

| ID | Requirement | Implementation evidence | Acceptance evidence | Status |
| --- | --- | --- | --- | --- |
| FR-01 | Run as an Android and iOS Flutter application | `android`, `ios`, `lib/main_mobile.dart` | Android debug APK builds and launches; iOS host is ready for Mac/Xcode validation | Implemented; iOS build pending Mac |
| FR-02 | Provide a separate dashboard that substitutes for unfinished hardware | `AppRole.input`, `POST /api/test-input` | Publish a 16-value frame and read the same frame from the collector | Implemented |
| FR-03 | Preserve the required device → mobile → API → database → web ownership path | transient input route, collector upload, Postgres store, history viewer | Integration test proves publication alone writes zero rows, then collector upload writes 16 | Implemented |
| FR-04 | Support 16 voltage channels | shared count of 16, UI fields/readouts, SQL channel check 0–15 | Payload tests reject the wrong number of values; a valid frame creates 16 rows | Implemented |
| FR-05 | Reject invalid voltages | Flutter input validation, server validation, SQL range check | Values outside −5 V through +5 V receive HTTP 400 and do not write | Implemented |
| FR-06 | Let the operator explicitly start and stop capture | collector Start/Stop state and stale-frame baseline | Widget test proves old, duplicate, and stopped frames do not upload | Implemented |
| FR-07 | Log captured data locally before upload and retry failures | `capture_log.dart`, native JSON and browser localStorage adapters | Restart/retry test preserves session, destination, timestamp, and pending state | Implemented |
| FR-08 | Persist sessions and measurements in PostgreSQL | `database/schema.sql`, `postgres-store.js` | Real-Postgres test closes the writer, opens a new reader, and finds the rows | Implemented |
| FR-09 | Provide a separate web history application | `AppRole.web`, session/detail routes | Manual smoke test selects a stored session and displays its values | Implemented |
| FR-10 | Filter history by time and graph a chosen channel | `history.dart`, inclusive API range filters | Dart and API tests cover valid, invalid, empty, and equal-boundary ranges | Implemented |
| FR-11 | Reserve randomized sensor sim-mode for future work | no random sensor generator | Controlled deterministic UDP scenarios are covered separately under FR-15 | Randomized sensor mode deferred |
| FR-12 | Let a user log in before accessing app data | optional single-user API credentials, bearer token, Flutter login form | API login/logout test and Flutter widget test verify protected reads | Implemented for local bench use |
| FR-13 | Discover, pair, and select an ESP32 sender | UDP receiver, discovered-source and pair routes, collector source selector | Socket test receives a v1 frame; API and widget tests verify pairing and source-specific reads | Implemented for local bench use |
| FR-14 | Document router and network setup for the firmware | `docs/device-connection.md`, `.env.example` | Steps cover Wi-Fi settings, destination IP, UDP/TCP ports, firewall, and emulator/phone API addresses | Documented; physical bench validation pending |
| FR-15 | Simulate network load and dropped data | `network-simulator.js`, `device-receiver.js`, Flutter Network lab | Actual UDP tests and `tools/demo-check.js` cover 100/1,000 fps, 20% dropped packets, corrupt frames, outage and recovery | Implemented |
| FR-16 | Provide a polished, repeatable demo and guide | `demo_widgets.dart`, isolated launcher, `docs/network-demo.md` | Phone-width layout test, login expiry test, browser walkthrough, automated rehearsal | Implemented |

## Non-functional requirements

| ID | Requirement | Evidence | Status |
| --- | --- | --- | --- |
| NFR-01 | Use only Flutter/Dart, Express, Node.js, PostgreSQL, AWS, and Vercel | Flutter clients, Express API, PostgreSQL schema; AWS/Vercel documented as deployment targets | Met for local MVP |
| NFR-02 | Remain deliberately minimal | Role-based screens, one API contract, one schema, no UI/chart framework dependency | Met |
| NFR-03 | Be understandable to another student developer | README plus focused architecture, API, development, mobile, history, demo, and verification documents | Met |
| NFR-04 | Behave predictably under retries and invalid input | database upsert, durable pending log, explicit validation, stable JSON errors | Met |
| NFR-05 | Be reproducible | `dev.cmd`, npm lockfile, Dart lockfile, `.env.example`, documented commands | Met on Windows; iOS requires macOS |

## Requirement changes

When scope changes, add or revise a row before implementing it. Record visual
requirements separately after the team agrees on them; do not silently convert
an aesthetic preference into a functional requirement.
