# AWS and Vercel deployment handoff

The current MVP is intentionally local. This document defines the deployment
boundary without claiming that cloud security or infrastructure has been
completed.

## Target topology

```text
Flutter Android/iOS ─┐
Manual Flutter web ──┼── HTTPS ── Express/Node on AWS ── PostgreSQL on AWS
Flutter history web ─┘
        hosted by Vercel
```

Vercel should serve only the compiled Flutter web files. AWS should run the
Express process and managed PostgreSQL. The mobile application communicates
directly with the HTTPS API; it does not communicate with Vercel to save data.

## Required configuration

The API needs:

- `PORT`, normally supplied by the AWS runtime;
- `DATABASE_URL`, supplied as a protected environment variable;
- an initialized database produced by `database/schema.sql`.

The Flutter build needs its public API origin at compile time:

```powershell
flutter build web --output=build/web-viewer `
  --dart-define=API_URL=https://api.example.edu
```

Android/iOS release builds use the same `API_URL` definition. Do not put a
database URL or database credential in Flutter; client applications know only
the Express URL.

## Pre-deployment gate

Do not expose this MVP publicly until the team has completed all of the
following:

1. Add authentication and define who can publish, collect, and read sessions.
2. Restrict CORS to the deployed Vercel origin instead of the local wildcard.
3. Use TLS for all traffic and require certificate-valid HTTPS URLs in release builds.
4. Store secrets only in the hosting platforms' protected environment settings.
5. Create a least-privilege database role; do not use the local trust setup.
6. Add database backups, restore testing, retention policy, and monitoring.
7. Add bounded/paginated history reads before collecting high-rate data.
8. Run the iOS build/test gate on macOS and sign both native applications.

## Deployment sequence

1. Provision PostgreSQL and a least-privilege application role on AWS.
2. Apply `database/schema.sql`; rerunning it is safe.
3. Deploy the Express app from `apps/api`, configure secrets, and check `/health`.
4. Run the API and real-database integration tests against a non-production test database.
5. Build Flutter web with the public HTTPS API URL and deploy the generated folder to Vercel.
6. Build signed Android/iOS clients with the same API origin.
7. Run the manual acceptance path in `demo.md` using non-sensitive test data.

## Rollback boundary

Keep the previous API and Flutter web artifacts available. Application rollback
must not delete or downgrade PostgreSQL data. Any future non-additive schema
change needs its own reviewed migration and recovery procedure; do not edit or
drop production tables interactively during a demonstration.
