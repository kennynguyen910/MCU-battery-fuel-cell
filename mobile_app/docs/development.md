# Developer guide

## Source map

| File | Responsibility |
| --- | --- |
| lib/main.dart | Native collector / web history default entry |
| lib/main_mobile.dart | Explicit collector entry |
| lib/main_input.dart | Explicit manual dashboard entry |
| lib/screens.dart | Plain UI, session selection, polling, Start/Stop |
| lib/history.dart | UTC filter controls and simple single-channel graph |
| lib/api.dart | HTTP encoding, timeout, error handling |
| lib/capture_log.dart | Durable frame lifecycle and retries |
| lib/log_storage_io.dart | Android/iOS JSON-file storage |
| lib/log_storage_web.dart | Browser preview storage |
| apps/api/src/app.js | Express routes and transient device input |
| apps/api/src/validation.js | Body, identifier, channel, and timestamp validation |
| apps/api/src/postgres-store.js | SQL queries, transactions, upserts |
| apps/api/src/memory-store.js | Nonpersistent test fallback |
| apps/api/src/server.js | Root .env and API startup |
| apps/api/src/preview.js | Serve the compiled Flutter bundle locally |
| tools/dev.js | Start database/API/preview and stop owned Node children |
| database/schema.sql | Tables, checks, primary/foreign keys, indexes |

## Tests and what they establish

- validation.test.js checks 16-channel payloads and input range.
- manual-input.test.js checks upload/readback and rejected writes.
- postgres-flow.test.js checks the complete input/collector/database/read path
  against real Postgres. Device publication alone must not create rows. Retrying
  an unchanged frame must not double the row count.
- collector_test.dart checks Start/Stop and suppresses duplicate/old frames.
- capture_log_test.dart checks failed upload, storage reload, and retry into the
  original session with its original timestamp.
- history_test.dart checks UTC dates, point ordering, invalid filter handling,
  equal endpoints, clearing filters, and the single-zero-sample graph.
- history-validation.test.js checks server date validation and malformed JSON.
  The Postgres flow test also verifies inclusive boundaries and empty ranges.
- http-errors.test.js checks stable 400/404 responses and proves unexpected
  internal details are not returned to clients.

Postgres integration runs only when TEST_DATABASE_URL is set. dev.cmd test sets
the local URL and starts the bundled database when needed. Tests retain labeled
test sessions for inspection and never truncate user tables.

## Debugging by boundary

1. GET /health should identify capstone, return status ok and storage postgres.
2. If the dashboard cannot publish, check the API address and voltage validation.
3. If values display on mobile but not web, ensure capture is running, the local
   log has no pending failures, and both screens select the same session.
4. If pending entries remain, verify their original API URL/session still exists.
5. If the web looks stale, keep its tab active and refresh after a new build.

The manual dashboard holds only the most recent frame. A frame published before
Start capture is intentionally not recorded. Publish another frame after Start.

## API/database details

The .env file is loaded relative to server.js, independent of working directory.
The local cluster is at .local/pgdata and listens only on 127.0.0.1:55432.
It uses a capstone development role/database and local trust authentication.
For an independently installed PostgreSQL server, change DATABASE_URL and apply
database/schema.sql with psql before starting the API.

Do not delete .local/pgdata to fix a startup problem; that is the persistent data.
Check .local/postgres.log. Tools and downloads under .tools can be reinstalled,
but database files and pending mobile logs are not disposable caches.

## Development commands

- dev.cmd: serve the built previews and API.
- dev.cmd build: compile Flutter web.
- dev.cmd app: run collector web preview with Flutter development tooling.
- dev.cmd android: build the emulator-targeted Android debug APK.
- dev.cmd test: backend tests, Flutter tests, and analysis.

For source checkout on another machine install Node/Flutter, run
`npm ci --prefix apps/api` and `flutter pub get` in `.`. Configure a
Postgres instance and copy `.env.example` to `.env`. This repository's
`.tools/.local` directories are machine-local and intentionally not committed.

## Work remaining

Firmware transport, high-rate buffering, authentication, production
signing, Vercel/AWS deployment, and aesthetics remain separate milestones.
The current demo is intentionally plain. Random sim-mode has not been added.
