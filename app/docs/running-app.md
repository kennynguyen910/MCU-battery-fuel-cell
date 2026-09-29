# Run the normal Capstone app

1. Double-click **`Start_Capstone.cmd`** in the project root (or
   `START_PROJECT/01_Start_WebApp.cmd`). Keep the terminal open.
2. The launcher updates changed screens, starts PostgreSQL, starts the API and
   device receiver, checks readiness, and opens the collector.
3. Log in with username **`capstone`**, password **`capstone_password`**.

This is the normal app. Sessions and measurements are saved in persistent local
PostgreSQL, in `.local/pgdata`. Closing and reopening the app does not erase them.
It does not create sample sessions, generate traffic, or start capture on launch.
The launcher works on this configured computer; a fresh checkout still needs
`executables/00_First_Time_Setup.cmd` once.

## Use a device

Connect the board using [the router/device guide](device-connection.md). In the
collector select **ESP32 over laptop Wi-Fi / UDP**, select the discovered board,
and press **Pair selected device**. Create a session and press **Start capture**
when ready. **Stop capture** stops accepting new samples; pending uploads finish.
Use **History** to view saved sessions. Returning to the collector requires
selecting the input again and explicitly starting capture.

The API listens on TCP 3001, the device receiver on UDP 5005, and the browser app
on http://localhost:5173/. A physical phone uses the laptop's LAN IPv4 address for
the API. The Android emulator uses http://10.0.2.2:3001. The same login works there.

## Optional network testing

Open **Network lab** after login. It starts in **Stopped**. Choose a scenario
only when you want to test load, dropped packets, corruption, or outages.
The loopback sender appears as **Simulator** in the collector. Pair it and use a
clearly named test session if you want to save synthetic readings. They persist
in the same local database, attached to their own device record. Select the
physical board's address for actual board data. Network lab statistics track
only the simulator, even if a real board is also sending.

The [presentation guide](network-demo.md) explains the scenarios. The old
`10_Start_Network_Demo.cmd` remains an optional temporary sandbox, separate from
the normal app. It uses the same login. Neither launch starts scenarios itself.

## Existing cloud database

The original `.env` cloud connection is preserved. Local and cloud histories
are separate; they are not automatically synchronized. Close the running app
terminal, then use `START_PROJECT/12_Start_Configured_Database.cmd` to use the
database configured in `.env`. This requires cloud network access. The cloud
connection was unreachable during this update, so the main launcher deliberately
uses local PostgreSQL to provide a reliable start.

Do not run the local and cloud launchers simultaneously on port 3001. The
launcher rejects a service with a different storage location or feature setup.
Ctrl+C stops the API/web services it started; PostgreSQL remains running.
If an older API window is open, close it before relaunching to apply new settings.
