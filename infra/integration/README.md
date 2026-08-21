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

M4 (S3) needs one; M3's WebDAV is already here. Add a service to `docker-compose.yml` and its settings to
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

## Public key authentication

`script.sh` generates three keys into `keys/` on first run — an Ed25519 key, the same with a passphrase, and
an RSA key — and the container reads every `*.pub` there into the account's `authorized_keys`. Password
authentication stays enabled, so the one container serves both.

The keys are **generated, not committed**: `keys/` is gitignored. A private key does not belong in git even
when it is worthless.

The RSA key exists to prove a limitation rather than a feature. DriverPro cannot authenticate with it, and
`SFTPPublicKeyIntegrationTests` asserts that the *refusal explains itself*. If that test ever starts failing
because the login succeeded, the SSH transport was replaced and
[ADR 014](../../docs/decisions/014-rsa-public-key-authentication-is-unavailable.md) should be superseded.

## ssh-agent

Gated separately, because loading a key into an agent is something a person does deliberately and a suite
that quietly used whatever was in your agent would be unpredictable:

```sh
eval "$(ssh-agent -s)"
ssh-add infra/integration/keys/id_ed25519
DP_AGENT_TESTS=1 infra/integration/script.sh
```

`script.sh` does not start an agent, in keeping with the rule above that the runner knows nothing
protocol-specific.

One thing that will bite: `sockaddr_un.sun_path` holds **104 bytes on macOS**, and a longer path is silently
truncated. `ssh-agent -a` in a deeply nested directory fails with "path too long"; anything reading such a
socket gets "no such file" for a socket that is plainly there.

## Worth knowing about the SFTP server

- **It is chrooted.** `sshd` runs with `ChrootDirectory %h`, so the client sees the account home as `/`
  and the writable directory as `/integration` — not `/home/user/integration`.
- **Host keys regenerate on every start**, so trust-on-first-use is exercised for real each run.
- **Your `~/.ssh/known_hosts` is never touched.** Each test gets a temporary file.

To see the fingerprint the app should display on first connect:

```sh
ssh-keyscan -p 2222 -t ed25519 localhost | ssh-keygen -lf -
```
