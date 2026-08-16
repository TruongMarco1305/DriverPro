# Integration test infrastructure

Real servers for the integration tests. Nothing here ships with the app.

The default `swift test` is hermetic and offline — every suite in here is gated behind an environment
variable and skips when it is unset. Start a service when you want the coverage an in-memory fake
cannot give you.

## Usage

```sh
infra/integration/script.sh
```

Starts every service, runs the whole test suite with the integration tests enabled, and tears them
down again — including if the tests fail or you interrupt it. Requires Docker.

## Files

| File | Purpose |
|---|---|
| `script.sh` | Runner. Starts everything, runs the suite, tears it down; knows nothing protocol-specific. |
| `docker-compose.yml` | The services. |
| `.env` | Every service's configuration. The same names are what the tests read. |

## Adding a service

M3 (WebDAV) and M4 (S3) each need one. Add a service to `docker-compose.yml` and its settings to
`.env`, then gate the new suite behind its own `<SERVICE>_HOST` so the offline default stays offline.
**`script.sh` does not change** — it starts whatever compose defines, rather than growing a
subcommand or an argument per protocol.

## Why the config lives in `.env`

Each value has two readers: compose substitutes it into the service definition, and `script.sh` exports
it so the tests can read it. One name, read by both — the tests look up `SFTP_USER`, not a second
variable derived from it.

They were once written out in two places, and changing the password in one produced a server the tests
could not log into, with an authentication error that pointed at the code rather than the config.

`.env` is Docker's default, so a bare `docker compose -f infra/integration/docker-compose.yml up` picks
it up with no flag and gives you exactly the server the tests expect. Nothing secret goes in here.

## Worth knowing about the SFTP server

- **It is chrooted.** `sshd` runs with `ChrootDirectory %h`, so the client sees the account home as `/`
  and the writable directory as `/integration` — not `/home/user/integration`.
- **Host keys regenerate on every start**, so trust-on-first-use is exercised for real each run.
- **Your `~/.ssh/known_hosts` is never touched.** Each test gets a temporary file.

To see the fingerprint the app should display on first connect:

```sh
ssh-keyscan -p 2222 -t ed25519 localhost | ssh-keygen -lf -
```
