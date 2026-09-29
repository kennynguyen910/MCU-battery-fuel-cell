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

`APP_USERNAME` and `APP_PASSWORD` in `.env` seed the initial account, currently
`capstone` / `capstone_password`. Once a username exists, restarting or editing
these settings does **not** overwrite its password. `.env` still contains the
initial plaintext secret; keep it private. There is no password reset command yet.

On first use after this update, restart the API so it loads database-backed login.
The normal launcher still checks the configured initial account for readiness.
Accounts persist with the database. Local and configured/cloud databases have
separate account lists. The optional temporary demo retains its single fixed login.

All users share access to devices, sessions, and measurements. These accounts
provide login identities, not per-user ownership or roles. Login tokens remain
in server memory, expire after eight hours, and are invalidated by server restart.
Logging one token out does not log out other users.
