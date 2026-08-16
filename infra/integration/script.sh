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

echo "Starting services..."
compose up -d --wait

compose logs -f &

swift test --package-path Packages/DriverProKit
RESULT=$?

compose down -v

# Exit with the tests' status, not the teardown's.
exit $RESULT
