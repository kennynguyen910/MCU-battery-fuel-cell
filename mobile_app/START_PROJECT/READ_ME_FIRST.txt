CAPSTONE PROJECT - DOUBLE-CLICK LAUNCHERS

NORMAL APP: Run 01_Start_WebApp.cmd or Start_Capstone.cmd in the project root.
Username: capstone   Password: capstone_password
The app builds changed screens and starts its services automatically.
Data persists in local PostgreSQL. Capture and simulation start stopped.
Read docs/running-app.md for normal use and the separate cloud option (12).

OPTIONAL TEMPORARY NETWORK SANDBOX:
Run 10_Start_Network_Demo.cmd only if you want isolated temporary test data.
It uses the same login and opens Network lab. Keep that terminal open.
Run 11_Check_Network_Demo.cmd for the automated rehearsal.
Read docs/network-demo.md for the full presentation script and recovery steps.
This isolated demo uses temporary data; it needs no AWS password or board.

1. Run 01_Start_WebApp.cmd. It starts local PostgreSQL, the API, device receiver,
   and web app, then opens the collector. Keep its terminal open.
   If they are already running, use http://localhost:5173/ directly.

2. Run 02_Start_Android_Emulator.cmd. Wait for the Android home screen.
   Then run 03_Install_And_Open_Android_App.cmd.
   Android needs the API started in step 1.

3. Run 04_Prove_AWS_Database.cmd. Enter the RDS password at the hidden
   prompt. It prints the connection identity, SSL status, table counts,
   and recent sessions. These queries do not modify records.

4. Optional: run 05_Open_Database_In_pgAdmin.cmd to browse the tables.

5. Run 09_Open_Manual_Input.cmd to enter and publish all 16 channel values.
   Start capture in the mobile collector BEFORE publishing a new frame.
   Each captured frame adds 16 database rows. Refresh website history and
   query the local database to compare the same session's saved values.
   AWS checks refer to the separate cloud database, not this default local data.

06 runs tests. 07 rebuilds the web app and opens it after services are ready.
08 rebuilds the Android APK. Background web-service logs are in .local.

This folder contains launch scripts. Keep it inside the Capstone project;
it depends on the adjacent executables, tools, apps, .tools and .env.
It is not a standalone portable application bundle.

AWS access requires the laptop's current public IP in the RDS security
group: PostgreSQL TCP 5432, My IP only. Never use Anywhere/0.0.0.0/0.
The API must report PostgreSQL mode. The Android emulator uses
http://10.0.2.2:3001; website history is http://localhost:5173/.

iOS is deferred. No iOS setup is needed for these launchers.
