# Login, pairing, and network demo

**For normal use, run `Start_Capstone.cmd` and follow [Running the app](running-app.md).**
Log in as `capstone` with `capstone_password`. The normal app saves to local
PostgreSQL and starts capture/simulation stopped. Its Network lab offers the same
manual scenarios below. The temporary sandbox described here is optional.

Use this guide for the TA demonstration. Allow 8–10 minutes. The demo uses
synthetic 16-channel measurements encoded in the ESP32's real UDP packet format.
No board, router changes, database password, or cloud connection is needed.

## 1. Prepare before presenting

1. Double-click `START_PROJECT/10_Start_Network_Demo.cmd`. It rebuilds the web
   screens if needed, starts the isolated demo, and opens Network lab.
2. Keep its terminal open. Username: `capstone`; password: `capstone_password`.
   Only this optional sandbox creates a new temporary dataset each launch.
3. Open the printed **Collector** and **History** links in separate tabs. Use the
   complete links, including the query string. Log in to each tab. Keep only one
   collector open. Navigation within one tab retains login, but leaving the
   collector screen stops its capture; separate tabs are useful for presenting.
4. Double-click `START_PROJECT/11_Check_Network_Demo.cmd` for the automated
   rehearsal. It runs independently on spare ports, takes about 20 seconds, and
   writes `.local/network-demo-report.json`. All checks should pass.

The demo binds HTTP `127.0.0.1:3301` and UDP `127.0.0.1:15005`. It uses temporary
memory storage and does not read `.env` or modify the normal database. Closing
the terminal ends the demo and discards its server data. Browser logs are
separated by demo run. The normal system remains at ports 3001/5173.

On another PC, run the repository's first-time setup before these launchers.
Command-line equivalents from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/prepare-demo.ps1
node tools/demo-check.js
```

## 2. Presentation script

| Time | Action | What to show or say |
| --- | --- | --- |
| 0:00 | Enter one wrong password, then `capstone_password`. | Incorrect login is rejected; protected data appears after successful login. This is a single operator account. |
| 1:00 | In Network lab choose **Run baseline · 100 fps**. | The sender and receiver counters increase. Source `127.0.0.1` becomes LIVE. Frames travel through a real UDP socket. |
| 2:00 | In Collector select **ESP32 over laptop Wi-Fi / UDP**, select the sender, then **Pair selected device**. | Device login means selecting and registering a discovered sender in the app. |
| 2:30 | Name the session, press **Create session**, then **Start capture**. | All 16 voltages update. Uploaded frames increase; pending uploads normally return to zero. |
| 3:00 | In History select the session. | Each captured sample has 16 saved channel rows. Show the channel graph and latest readings. Return to the collector periodically so the browser does not throttle it. |
| 4:00 | In Network lab choose **High load · 1,000 fps**. Wait 5 seconds. | Receiver throughput rises toward 1,000 valid frames/s. The collector fetches buffered frames and uploads batches. Compare uploaded frames with received frames, allowing the pending batch to finish. The screen still refreshes once a second. |
| 5:00 | Choose **Drop 20% of packets**. Wait 5 seconds. | Deliberately dropped frames and estimated missing frames rise. Each dropped UDP packet contains 10 frames. Receiver throughput is about 800 frames/s. |
| 6:00 | Choose **CRC corruption · 1 in 10**. Wait 5 seconds. | One frame in every tenth packet has a bad CRC. CRC errors rise; other frames in the packet remain usable. About 990 valid frames/s are expected. |
| 7:00 | Choose **Disconnect network**. Wait at least 6 seconds. | The sender generates but drops everything. The receiver becomes OFFLINE, throughput falls to zero, collector live values clear, and new uploads stop. |
| 7:30 | Choose **High load · 1,000 fps** again. | LIVE returns, voltages recover, and capture resumes if it was left running. Missing-frame estimates jump when the next sequence reveals the outage. |
| 8:00 | In Collector press **Stop capture**. Allow pending uploads to finish. Check History again. | New samples stop being stored even though receiver traffic continues. |
| 8:30 | Press **Log out**. Finish with **Stop generator** in Network lab. | Protected data is hidden after logout and the token is revoked. The report can be inspected with **View report JSON**. |

Suggested explanation: “The operator logs in, pairs a discovered device, and
starts a session. The receiver validates incoming packets. The collector controls
what gets logged and uploaded. This lab lets us deliberately test load, packet
loss, corrupt data, and recovery.”

## 3. Read the counters correctly

- **Sender counters** report the conditions deliberately injected by the lab.
  They accumulate across scenario changes; compare before/after values.
- **Receiver counters** report valid frames, forward sequence gaps, duplicate or
  late frames, and CRC errors. Gaps are estimates, not packet acknowledgements.
  A missing final packet only becomes visible when a later sequence arrives.
  Loss before the first received frame cannot be measured. Late frames do not
  subtract previously counted gaps. Corrupt frames can also create gaps.
- **Frames in last second** is a rolling measurement. Scheduling and background
  browser tabs affect timing; do not require the display to show exactly 1,000.
- **Scheduler skips** distinguish generator delays on a busy computer from
  intentional drops. Socket errors should remain zero.
- Counters reset when the demo server restarts. Scenario changes preserve them.

## 4. Real router and device setup

Follow [Connect the ESP32 to the app](device-connection.md) for the real bench:
private 2.4 GHz Wi-Fi, laptop and ESP32 DHCP reservations, firmware destination
IP, UDP 5005, API TCP 3001, private-network firewall rules, and phone/emulator
addresses. Pair the board's actual IPv4 address in the normal collector.

The loopback demo tests protocol handling and app behavior. It does not test
radio range, router isolation, physical sensors, or Wi-Fi performance. Reserve
both laptop and board addresses so firmware routing and app pairing stay stable.

## 5. Recovery during the demo

| Symptom | Recovery |
| --- | --- |
| Login fails | Use username `capstone`, password `capstone_password`. After restarting the sandbox, reopen the newly printed links. |
| No sender listed | Start Baseline or High load in Network lab; then wait a second in Collector. Confirm the API address is `http://127.0.0.1:3301`. |
| Create session / Start capture disabled | Pair a live sender first. Create or select a session. Finish any action already in progress. |
| History is empty | Start capture, select the same session in History, and keep Collector active for several seconds. Receiver traffic alone does not save measurements. |
| Collector shows offline | Resume Baseline or High load. Offline detection takes five seconds; receiving a valid new frame clears it. |
| Values update slowly | Bring the collector tab forward. Browsers throttle hidden tabs. Allow the one-second polling cycle to finish. |
| Port in use | Use the existing demo terminal or close it with Ctrl+C before relaunching. Do not stop the normal database to fix this. |
| Old screen after rebuilding | Refresh the page; if necessary close old demo tabs and reopen the links from the current launch. |
| Logged out or login expired | Log in again, select your session, and explicitly press Start capture. Signing in does not automatically restart capture. |

## Scope you can honestly claim

Implemented: user login/logout, app-side device pairing, router setup guide,
validated UDP reception, load/loss/corruption/outage scenarios, receiver metrics,
local logging, session history, responsive screens, and a repeatable rehearsal.
The normal system uses PostgreSQL; this isolated demo uses temporary storage.

Still outside this demonstration: physical-board throughput validation,
cryptographic device identity, multiple user accounts/roles, production
TLS/deployment, and an iOS build on Windows. IP pairing does not authenticate a
board's hardware identity. The firmware reference currently generates FakeADC
data. History charts show the latest 1,000 frames; the database retains all stored
frames. The local log keeps pending uploads and the latest 500 uploaded frames.
Keep capture in the foreground; long suspensions can exhaust the receiver buffer.
