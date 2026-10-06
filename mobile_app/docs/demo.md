# MVP demo runbook

**For this week's login, device pairing, and network testing demo, use the
[network demo guide](network-demo.md).** It includes a one-click launcher,
load/drop/corruption/outage scenarios, expected results, and a presentation script.
The manual-input walkthrough below is an alternative for the normal database.

This is the shortest reliable demonstration of the current system. Allow five
minutes. Keep the PowerShell window that runs the servers open.

## Before the audience arrives

1. Open PowerShell in the Capstone repository folder.
2. Run `./dev.cmd`.
3. Confirm the terminal says `PostgreSQL: already running` (or `started`),
   `Flutter previews`, and `API listening`.
4. Open these three tabs:
   - History: http://localhost:5173/
   - Collector: http://localhost:5173/?preview=mobile#/mobile
   - Device input: http://localhost:5173/?preview=input#/input
5. In the collector, press **Create session**, then **Start capture**.

The session dropdown in the collector and history page should name the same
session. Use only one collector during the demonstration.

## Demonstrate the complete path

1. In Device input, enter `1.234` for CH 1 and `-0.500` for CH 2.
2. Press **Publish device frame** once.
3. Wait about two seconds.
4. Show the collector values and its uploaded/pending counts.
5. Switch to History and select the new session if necessary.
6. Point out the saved values and graph. The database contains 16 rows per
   published frame—one row for every channel.
7. Publish a different CH 1 value and show the second graph point.
8. Press **Stop capture**, publish once more, and show that no new database
   point appears. This demonstrates that the mobile app controls capture.

## What each screen proves

- **Device input** publishes manual test readings. The separate ESP32 UDP path
  is described in [device connection](device-connection.md).
- **Collector** is the Android/iOS Flutter app. It decides when to capture,
  writes a durable local log first, and uploads pending frames.
- **History** is the read-only web application. It reads stored measurements
  from Express/PostgreSQL and supports UTC filtering and channel graphs.

## Fast recovery

- Browser page says disconnected: ensure `./dev.cmd` is still running, then
  press **Connect** or refresh.
- Port already in use: use the terminal that is already running the project;
  do not launch a second copy.
- Collector does not upload: select/create a session, press **Start capture**,
  and publish a new frame. Old frames are intentionally ignored at start.
- History shows another test: select the newly created session.
- Hidden browser tabs update slowly: bring the collector tab forward before
  publishing, or allow a few more seconds.
- Need a fresh APK: run `./dev.cmd android`. The file is
  `build/app/outputs/flutter-apk/app-debug.apk`.

## Honest scope statement

This MVP demonstrates the intended end-to-end ownership and persistence path.
It does not prove a physical-board connection, production deployment, full-rate
storage, or randomized sensor simulation. Login, pairing, and controlled UDP
network simulation are available in the network demo. iOS source is present, but Apple
requires macOS/Xcode to produce and run the iOS binary.
