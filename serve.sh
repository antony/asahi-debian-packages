#!/bin/sh
# Serve the apt repository over HTTP.
#
# Usage: ./serve.sh [port] [bind-address]
#
# Defaults to port 8321 on 127.0.0.1. The repo is unsigned (clients use
# [trusted=yes]), so keep it bound to localhost - do not expose it to
# the network or the internet.
set -eu

PORT="${1:-8321}"
BIND="${2:-127.0.0.1}"

cd "$(dirname "$0")/repo"

if [ ! -f Packages.gz ]; then
    echo "repo/Packages.gz missing - run ./update-index.sh first" >&2
    exit 1
fi

echo "Serving apt repo on http://${BIND}:${PORT}"
echo
echo "On the client, add this apt source:"
echo "  deb [trusted=yes] http://${BIND}:${PORT} ./"
echo
exec python3 -m http.server "$PORT" --bind "$BIND"
