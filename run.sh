#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then set -a; . ./.env; set +a; fi

if [ -z "${TYPESAFE_API_KEY:-}" ]; then
  echo "TYPESAFE_API_KEY is not set. Put it in .env next to this script as:"
  echo "  TYPESAFE_API_KEY=sk-..."
  echo "Get one at https://console.typesafe.ai/"
  exit 1
fi

if [ ! -x ./listen ] || [ listen.swift -nt ./listen ]; then
  echo "building listener..."
  swiftc -O listen.swift -o listen \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist 2>/dev/null
fi

echo "talk. one long sentence is the point. ctrl-c to stop."
./listen | .venv/bin/python agent.py "$@"
