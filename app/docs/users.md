# User accounts

## Add an account

1. Start the normal app with `Start_Capstone.cmd`.
2. Open `START_PROJECT/13_Add_User.cmd`.
3. Enter a new username, a password of at least 12 characters, and confirmation.
4. Log in with the new account on the mobile app or website. No restart is needed
   after adding users.

Usernames are case-sensitive and accept letters, numbers, dots, underscores, and
hyphens (up to 100 characters). Passwords accept 12–1000 characters and are hidden
while entered. Duplicate usernames are rejected without changing their password.

The command uses the same local database as the normal launcher. For the separate
database configured in `.env`, run from the project folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/add-user.ps1 -ConfiguredDatabase
```

## Storage and initial account

The API creates the PostgreSQL `app_user` table automatically on startup. It holds
the username, a random per-user salt, a scrypt password hash, and creation time.
Passwords are not stored as plaintext in this table or passed as command arguments.

`APP_USERNAME` and `APP_PASSWORD` in `.env` seed the configured initial account.
Once a username exists, restarting or editing
these settings does **not** overwrite its password. `.env` still contains the
initial plaintext secret; keep it private. There is no password reset command yet.

On first use after this update, restart the API so it loads database-backed login.
The normal launcher still checks the configured initial account for readiness.
Accounts persist with the database. Local and configured/cloud databases have
separate account lists. The optional temporary demo retains its single fixed login.

## Session ownership

| Account | Saved sessions and readings |
| --- | --- |
| `capstone_admin` (exact spelling) | All users' sessions, including preserved older sessions |
| Any other user, including `WillAdcox` | Only sessions created while signed in as that user |

Ownership is set by the API from the authenticated token when a session is
created. A client cannot choose or change the owner. List, history, upload and
delete routes enforce the same scope. A guessed foreign session ID receives
the same 404 response as a missing session. Admin can also upload or delete
across sessions; the existing confirmation still applies to deletion.

Older sessions have no reliable creator information. They remain unassigned
and admin-only, as requested. No session, reading, user, device or password is
deleted or reassigned by this upgrade. Shared bench devices, discovery, pairing,
provisioning and live transports remain available to authenticated users.

The collector's local log also filters by account and API address. New frames
retain the capturing user's identity through retries and restarts. Other users'
pending frames stay stored but are not displayed or retried by an ordinary
account. Admin can inspect/retry all frames at that API, including unassigned
older logs. Sign out stops capture and settles in-flight local saves/uploads;
the next sign-in clears the previous user's history and session selection.

Tokens remain in server memory, expire after eight hours, and are invalidated
by server restart. Logging one token out does not log out other users.

## Activate the tested upgrade when convenient

Development and test builds use the integration checkout and an isolated test
database. The currently running API, website build, account list and measurement
database are left available while development runs.
`dev.cmd test` also creates and removes its own temporary database for API
regression tests, so it does not migrate the app database or add test accounts
and sessions to it.

1. Finish capture and allow pending uploads to settle in the current app.
2. At a convenient stopping point, close the current app launcher/API and run
   `Start_Capstone.cmd` from the updated application checkout. This rebuilds the
   browser if necessary and starts the updated API. A running old API must be
   closed explicitly; the launcher reuses healthy processes.
3. API startup adds nullable `test_session.owner_username` and creates its owner
   index concurrently. Migration is idempotent; it preserves existing keys,
   relationships, constraints and values. A busy-table lock fails startup after
   two seconds so migration can be retried when capture has settled.
4. Reload the browser and sign in again. Update the Android app with the new
   APK as well, so account filtering also applies to its local cache.
5. Use `capstone_admin` to verify older sessions. Use `WillAdcox` or another
   ordinary account to create a new session and verify it is private. If the
   admin account does not exist, create that exact username with the existing
   Add User command; this upgrade never invents or resets a password.

Rollback to old binaries leaves the added column/index and all records intact,
but old APIs share sessions again. Ownership enforcement requires the new API;
do not use a rollback as a privacy-preserving deployment.

Capture tests cover authenticated 1,000 and 2,000 frames/s with blocked
history/uploads. The earlier 6kSPS capacity profile belongs to its recorded
revision; this ownership upgrade has not been reprofiled at that upper bound.
