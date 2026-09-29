# Capstone launchers (Windows)

Keep this folder inside the Capstone repository; it uses the adjacent apps,
tools, and ignored local configuration. These are launchers, not standalone
copies of the installed SDKs. iOS is deferred.

1. Run `02_Start_API.cmd` and keep it open. It should report PostgreSQL mode.
2. Run `03_Start_Web_Previews.cmd` and keep it open.
3. Run `04_Open_Dashboards.cmd` for the website, mobile preview, and manual input.
4. For native Android, run `05_Start_Android_Emulator.cmd`, wait for boot,
   then run `06_Install_And_Open_Android_App.cmd`.
5. Run `07_Prove_AWS_Postgres.cmd` to show the SQL connection proof. Type the
   database password into its hidden prompt. The queries do not modify data.
6. Run `08_Open_pgAdmin.cmd` to browse the database in a PostgreSQL client.
7. Run `09_Open_Manual_Input.cmd` for the dedicated 16-channel input page.
   It starts missing services automatically. Start mobile capture before publishing.

## pgAdmin connection

Register a server named Capstone AWS PostgreSQL if it is not already listed:

- Host: capstone-postgres.cj0kowcoegeo.us-east-2.rds.amazonaws.com
- Port: 5432
- Maintenance database: capstone
- Username: capstone_admin
- SSL mode: verify-full
- Root certificate: `.local/aws/global-bundle.pem` in this repository (use its
  full path in pgAdmin).

Enter the password privately. Expand Databases > capstone > Schemas > public >
Tables. Right-click measurement or test_session > View/Edit Data > All Rows.

## Prove mobile to website

In the collector, create a unique session and start capture. In manual input,
publish all 16 values. Wait for Uploaded 1 frame / Pending 0, stop capture,
then refresh website history and select the session. Confirm 16 stored rows.
Run the SQL proof and confirm the same session has one sample and 16 rows.

The Android emulator uses http://10.0.2.2:3001. A physical phone needs a reachable
API address entered in the app. The API host must stay running. Database
credentials belong only on the API host. If its public IP changes, update the
RDS security group's TCP 5432 source to the current My IP /32.

Use `90_Run_All_Tests.cmd` to verify, `91_Build_Web.cmd` to rebuild the website,
and `92_Build_Android.cmd` to rebuild the APK. The APK is at
`apps/monitor/build/app/outputs/flutter-apk/app-debug.apk`.
