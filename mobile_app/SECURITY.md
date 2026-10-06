# Security scope

This is a local, unauthenticated MVP and must not be exposed directly to the
public internet. It uses loopback-only PostgreSQL trust authentication and broad
development CORS so three local Flutter roles can communicate easily.

Do not commit credentials, `.env`, `.local`, database backups, mobile capture
logs, signing material, or generated SDK folders. If a secret is accidentally
committed, revoke it before removing it from history.

Before AWS/Vercel deployment, complete every item in the production gate in
`docs/deployment.md`, especially authentication, HTTPS, restrictive CORS,
least-privilege database access, backup/restore testing, and bounded reads.

For a security concern, notify the student team privately instead of opening a
public issue containing credentials, private test data, or an exploitable URL.
