#!/usr/bin/env bash
set -uo pipefail
INTEGRATION="$(cd "$(dirname "$0")" && pwd)"
cd "$INTEGRATION/../.." || exit 1

ENV_FILE="$INTEGRATION/.env"

# `set -a` exports everything defined while it is on, so these reach both compose and swift test.
set -a
. "$ENV_FILE"
set +a

compose() { docker compose --env-file "$ENV_FILE" -f "$INTEGRATION/docker-compose.yml" "$@"; }

# Keys for public key authentication, generated on first run rather than committed. A private key in git
# is a bad habit even when the key is worthless, and `ssh-keygen` is on every machine that can run this.
# The container reads every *.pub in this directory as authorized_keys.
KEYS="$INTEGRATION/keys"
mkdir -p "$KEYS"
[ -f "$KEYS/id_ed25519" ] || \
    ssh-keygen -q -t ed25519 -N "" -C "driverpro integration" -f "$KEYS/id_ed25519"
[ -f "$KEYS/id_ed25519_encrypted" ] || \
    ssh-keygen -q -t ed25519 -N "$SFTP_KEY_PASSPHRASE" -C "driverpro integration (encrypted)" \
               -f "$KEYS/id_ed25519_encrypted"
# RSA exists to demonstrate that it does *not* work, and that the failure explains itself. See ADR 014.
[ -f "$KEYS/id_rsa" ] || \
    ssh-keygen -q -t rsa -b 3072 -N "" -C "driverpro integration (rsa)" -f "$KEYS/id_rsa"

# The key paths are written repo-relative in `.env` because that is what a person reading it wants to see,
# and compose resolves them that way too. `swift test --package-path` runs with the *package* as its working
# directory, not the repo root, so relative paths would not resolve there. Absolutise them here — this
# script already knows the root, and the tests should not have to guess it.
export SFTP_KEY_PATH="$PWD/$SFTP_KEY_PATH"
export SFTP_ENCRYPTED_KEY_PATH="$PWD/$SFTP_ENCRYPTED_KEY_PATH"
export SFTP_RSA_KEY_PATH="$PWD/$SFTP_RSA_KEY_PATH"

echo "Starting services..."
compose up -d --wait

compose logs -f &

swift test --package-path Packages/DriverProKit
RESULT=$?

compose down -v
rm -r $KEYS

# Exit with the tests' status, not the teardown's.
exit $RESULT
