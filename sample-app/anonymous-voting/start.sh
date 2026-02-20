#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Build browser bundle if it doesn't exist or source is newer
if [ ! -f bundle.js ] || [ src/browser-entry.ts -nt bundle.js ]; then
  echo "==> Building browser bundle..."
  node build.mjs
fi

echo "==> Starting server..."
node server.ts
