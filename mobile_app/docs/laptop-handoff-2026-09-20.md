# Laptop database handoff — 2026-09-20

## Verified connection

The Flutter mobile collector browser preview uploaded a complete sample through
the Express API to AWS RDS. The website read the same persisted sample. Native
Android startup is verified in the emulator; a native-screen upload has not
been independently exercised. The debug APK built and installed successfully.

- RDS instance: `capstone-postgres`, Available in us-east-2.
- Security group: `capstone-rds-local`, TCP 5432 from `165.91.13.200/32` only.
- API health: `{"service":"capstone","status":"ok","storage":"postgres"}`.
- Session: `Laptop handoff 2026-09-20 Codex`.
- Session ID: `0ffe8e28-8c41-48f4-9fbe-be639c98ebfb`.
- Sample timestamp: `2026-09-20T16:43:38.681Z`.
- Mobile collector: 1 uploaded frame, 0 pending.
- Website, API, and SQL: 16 measurement rows; channels 1–16 contain 0.1–1.6 V.
- SQL totals before: 2 devices, 5 sessions, 4176 rows.
- SQL totals after: 3 devices, 7 sessions, 4192 rows.
- An extra empty `Manual bench test` session was created while entering the
  handoff name; it has zero measurements and was retained.

## Reproduce the terminal proof

Use the existing hidden password prompt; never paste credentials into commands
or screenshots. From the repository root:

```powershell
& .\.tools\pgsql\bin\psql.exe "host=capstone-postgres.cj0kowcoegeo.us-east-2.rds.amazonaws.com port=5432 dbname=capstone user=capstone_admin sslmode=verify-full sslrootcert=.local/aws/global-bundle.pem" -W
```

```sql
SELECT current_database(), current_user, inet_server_addr(), inet_server_port();
SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();
SELECT (SELECT COUNT(*) FROM monitor_device) AS devices,
       (SELECT COUNT(*) FROM test_session) AS sessions,
       (SELECT COUNT(*) FROM measurement) AS measurement_rows;
SELECT s.session_name, COUNT(DISTINCT m.recorded_at) AS samples,
       COUNT(m.measurement_id) AS measurement_rows,
       MAX(m.recorded_at) AS last_measurement
FROM test_session s LEFT JOIN measurement m USING (session_id)
GROUP BY s.session_id, s.session_name
ORDER BY s.start_time DESC LIMIT 10;
```

Observed connection: `capstone`, `capstone_admin`, `172.31.14.137`, port 5432.
Observed SSL: `t`, `TLSv1.3`, `TLS_AES_256_GCM_SHA384`.
The handoff session returned 1 sample and 16 rows in the final SQL query.

## Launch and verification

Run `executables/02_Start_API.cmd` and `03_Start_Web_Previews.cmd`, keeping both
running. Open `http://localhost:5173/` for history and
`http://localhost:5173/?preview=mobile#/mobile` for the collector.
The manual input page is `http://localhost:5173/?preview=input#/input`.

`00_First_Time_Setup.cmd` succeeded. `90_Run_All_Tests.cmd` succeeded with
12 API tests and 6 Flutter tests, no failures or skips; analysis found no issues.
`91_Build_Web.cmd` and `92_Build_Android.cmd` succeeded.
The APK uses `http://10.0.2.2:3001`, the Android emulator address for this PC.
A physical phone must use a reachable API address entered in its connection
field; physical-phone connectivity and a public API deployment were not tested.
Database credentials remain on the API host, never in Flutter or web output.

## Laptop repairs and remaining native check

Restored five missing tracked tools from commit `3a8855f`. Refreshed Flutter
package paths copied from the old machine. Quarantined invalid generated Gradle
transforms under `.tools/gradle/caches/9.3.1/transforms.handoff-stale*`; those
recoverable caches are ignored by Git. Regeneration fixed the Android build.

Fixed Windows PowerShell treating Java's successful stderr version banner as
an error in Android setup. The legacy PowerShell environment also lacked
`Get-FileHash`; running the setup script with the available PowerShell 7 runtime
verified the downloaded archive and created `Capstone_Test`. The SDK reported
six optional licenses unaccepted; no licenses were accepted automatically.
The existing installed packages sufficed to rebuild the APK and boot Android.
Launchers 05 and 06 successfully booted the emulator, installed the APK, and
started `com.example.capstone_monitor/.MainActivity`; its process remained
running with no Flutter/AndroidRuntime crash in the inspected logs.
The final official test run after the repair passed all 18 tests and analysis.

`.env`, `.local`, `.tools`, dependencies, and generated builds are Git-ignored.
The API must stay running for either client to reach RDS. When the laptop's
public IP changes, update the restricted RDS inbound rule to its new /32.
iOS build/signing requires macOS.
