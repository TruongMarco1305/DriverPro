# Integration test infrastructure

Real servers for the integration tests. Nothing here ships with the app.

The default `swift test` is hermetic and offline — every suite in here is gated behind an environment
variable and skips when it is unset. Start a service when you want the coverage an in-memory fake
cannot give you.

## Usage

```sh
infra/integration/script.sh              # everything
infra/integration/script.sh sftp         # SFTP only
infra/integration/script.sh webdav       # the plain WebDAV server and its TLS front
infra/integration/script.sh nextcloud    # Nextcloud only
infra/integration/script.sh s3           # MinIO, and the buckets the S3 tests browse
infra/integration/script.sh localstack   # LocalStack's S3, the second implementation
```

Starts what is asked for, runs the suite, and tears it down again — including if the tests fail or you
interrupt it. Requires Docker.

A bare run still tests everything, which is what a release check wants. The argument only narrows it.

## Features

| Feature | Services | Roughly |
|---|---|---|
| `sftp` | `sftp` | a second to start |
| `webdav` | `webdav`, `webdav-tls` | a second or two |
| `nextcloud` | `nextcloud` | most of a minute — it lays out a database on first start |
| `s3` | `minio` | a second or two |
| `localstack` | `localstack` | ten seconds or so — it starts its S3 service on boot |

**Why S3 has two features.** MinIO and LocalStack are both "S3", and that is exactly why both are here.
M3 learned the lesson the expensive way: the session contract passed against Apache's `mod_dav` and
failed against Nextcloud, over a response-cache behaviour neither server documents. One implementation
is not evidence about another, and "S3-compatible" is a family of dialects rather than a specification.
The five real providers — AWS, GCS, R2, B2, Spaces — cannot run in Docker at all, and are covered by the
conformance matrix in `docs/milestones/M4-acceptance.md`.

**Why the split.** This began as one service, and the runner deliberately took no argument: it started
whatever compose defined, and that was right. With four services it is not. A one-line change to the
SFTP backend should not wait for Nextcloud to install, and when something does fail, four servers
competing for the machine make it much harder to say what failed.

The mechanism is worth knowing because it is what keeps the runner simple:

- **Compose profiles** decide what starts. Every service carries one, so `--profile` — or
  `COMPOSE_PROFILES`, which `.env` sets to all of them — chooses.
- **The tests select themselves.** Every suite is gated on its own `<SERVICE>_HOST`, so the runner does
  not filter by name; it simply does not export the other features' host settings, and those suites skip
  for the reason they were built to skip. No regex over suite names to fall out of date.

Check the run's output for skips rather than assuming: a feature run that started nothing would
otherwise look green because its tests never ran.

## Files

| File | Purpose |
|---|---|
| `script.sh` | Runner. Starts a feature or all of them, runs the suite, tears it down. |
| `docker-compose.yml` | The services, each behind a profile. |
| `.env` | Every service's configuration. The same names are what the tests read. |

## Architecture, and why it is not `linux/amd64` everywhere

Every service here was once pinned to `platform: linux/amd64`. On an Apple Silicon machine that means
Docker emulates the container, and for an `sshd` or an Apache serving a scratch directory the cost is
invisible.

For Nextcloud it was not. Emulated, it was slow enough to break rather than merely drag: plain
`PROPFIND`s against an idle server timed out three times in five, and the suite failed with timeouts and
with errors about files that a previous, silently-stalled request had never created. Every one of those
looked like a bug in DriverPro's WebDAV client. None were. Running it natively took the same suite from
191 seconds and three failures to 4 seconds and none.

**So pin only the images that leave no choice.** `atmoz/sftp` and `bytemark/webdav` publish amd64 alone
and are small enough not to care. `caddy` and `nextcloud` publish `arm64` and must be allowed to use it.

```sh
docker manifest inspect <image> | grep architecture
```

Worth running before adding a service in M4. And if an already-pulled image is the wrong architecture,
compose will keep reusing it — `docker pull --platform linux/arm64 <image>` first, then check:

```sh
docker exec <container> uname -m
```

## Adding a service

Three places, all in this directory — and getting only one of them is worse than getting none, because
compose validates the **whole** file whatever profile you ask for. A half-written service breaks every
other feature's run, not just its own:

1. A service in `docker-compose.yml`, with a `profiles:` key naming its feature.
2. Its settings in `.env`, including `<SERVICE>_HOST`, and the feature added to `COMPOSE_PROFILES`.
3. A row in `script.sh`'s feature table — the name, and which `_HOST` variable it owns.

Then gate the new suite behind that `<SERVICE>_HOST` so the offline default stays offline. The runner
still knows nothing protocol-specific: the table says which name maps to which setting, and nothing
else about the protocol.

Check the file still parses before running anything — this is the one-second version of the paragraph
above, and it fails loudly where compose otherwise fails at `up`:

```sh
docker compose --env-file .env config -q      # silence is success
```

And write the suite *with* the service. A feature that starts a server and runs nothing reports green,
for exactly the reason in the warning further up.

## Why the config lives in `.env`

Each value has two readers: compose substitutes it into the service definition, and `script.sh` exports
it so the tests can read it. One name, read by both — the tests look up `SFTP_USER`, not a second
variable derived from it.

They were once written out in two places, and changing the password in one produced a server the tests
could not log into, with an authentication error that pointed at the code rather than the config.

`.env` is Docker's default, so a bare `docker compose -f infra/integration/docker-compose.yml up` picks
it up with no flag and gives you exactly the servers the tests expect — `COMPOSE_PROFILES` in there is
what keeps that working now every service sits behind a profile. Nothing secret goes in here.

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
DP_AGENT_TESTS=1 infra/integration/script.sh sftp
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
