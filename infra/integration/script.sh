#!/usr/bin/env bash
#
# Runs the integration tests against real servers, then tears them down.
#
#   script.sh              everything
#   script.sh sftp         SFTP only
#   script.sh webdav       the plain WebDAV server and its TLS front
#   script.sh nextcloud    Nextcloud only
#   script.sh s3           MinIO, and the bucket the S3 tests browse
#   script.sh localstack   LocalStack's S3, the second implementation to check against
#
# The argument narrows what starts. Without one, everything runs — which is what a release check wants,
# and what this script has always done.

set -uo pipefail
INTEGRATION="$(cd "$(dirname "$0")" && pwd)"
cd "$INTEGRATION/../.." || exit 1

ENV_FILE="$INTEGRATION/.env"

# `set -a` exports everything defined while it is on, so these reach both compose and swift test.
set -a
. "$ENV_FILE"
set +a

# What each feature is called, and which setting the tests read to know its server is there.
#
# The second half is what selects the tests, and it needs no `--filter`: every integration suite is
# gated on its own `<SERVICE>_HOST` being set, so unsetting the others makes them skip themselves. That
# rule is already in the README and every suite follows it — adding S3 in M4 is a row here rather than a
# change in logic.
FEATURES="sftp webdav nextcloud s3 localstack"
feature_host_variable() {
    case "$1" in
        sftp)       echo "SFTP_HOST" ;;
        webdav)     echo "WEBDAV_HOST" ;;
        nextcloud)  echo "NEXTCLOUD_HOST" ;;
        s3)         echo "S3_HOST" ;;
        localstack) echo "LOCALSTACK_HOST" ;;
    esac
}

REQUESTED="${1:-}"
if [ -n "$REQUESTED" ]; then
    case " $FEATURES " in
        *" $REQUESTED "*) ;;
        *)
            echo "Unknown feature “$REQUESTED”. Available: $FEATURES"
            echo "Run with no argument to test everything."
            exit 2
            ;;
    esac

    export COMPOSE_PROFILES="$REQUESTED"

    # Hide the other servers from the tests, so their suites skip rather than fail against something that
    # was never started.
    for feature in $FEATURES; do
        [ "$feature" = "$REQUESTED" ] && continue
        unset "$(feature_host_variable "$feature")"
    done
fi

compose() { docker compose --env-file "$ENV_FILE" -f "$INTEGRATION/docker-compose.yml" "$@"; }

# Keys for public key authentication, generated on first run rather than committed. A private key in git
# is a bad habit even when the key is worthless, and `ssh-keygen` is on every machine that can run this.
# The container reads every *.pub in this directory as authorized_keys.
KEYS="$INTEGRATION/keys"
mkdir -p "$KEYS"

# Only when SFTP is part of this run. Generating three keys costs a second and nothing else uses them —
# but the directory itself is always created, because compose mounts it and refuses to start without it
# even when the SFTP service is not in the profile.
if [ -z "$REQUESTED" ] || [ "$REQUESTED" = "sftp" ]; then
    [ -f "$KEYS/id_ed25519" ] || \
        ssh-keygen -q -t ed25519 -N "" -C "driverpro integration" -f "$KEYS/id_ed25519"
    [ -f "$KEYS/id_ed25519_encrypted" ] || \
        ssh-keygen -q -t ed25519 -N "$SFTP_KEY_PASSPHRASE" -C "driverpro integration (encrypted)" \
                   -f "$KEYS/id_ed25519_encrypted"
    # RSA exists to demonstrate that it does *not* work, and that the failure explains itself. See ADR 014.
    [ -f "$KEYS/id_rsa" ] || \
        ssh-keygen -q -t rsa -b 3072 -N "" -C "driverpro integration (rsa)" -f "$KEYS/id_rsa"
fi

# The key paths are written repo-relative in `.env` because that is what a person reading it wants to see,
# and compose resolves them that way too. `swift test --package-path` runs with the *package* as its working
# directory, not the repo root, so relative paths would not resolve there. Absolutise them here — this
# script already knows the root, and the tests should not have to guess it.
export SFTP_KEY_PATH="$PWD/$SFTP_KEY_PATH"
export SFTP_ENCRYPTED_KEY_PATH="$PWD/$SFTP_ENCRYPTED_KEY_PATH"
export SFTP_RSA_KEY_PATH="$PWD/$SFTP_RSA_KEY_PATH"

echo "Starting services: $COMPOSE_PROFILES"
compose up -d --wait || exit 1

compose logs -f &

swift test --package-path Packages/DriverProKit
RESULT=$?

compose down -v
rm -r "$KEYS"

# Exit with the tests' status, not the teardown's.
exit $RESULT
