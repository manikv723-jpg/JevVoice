#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
if [ ! -x ./listen ] || [ listen.swift -nt ./listen ]; then
  echo "building listener..."
  swiftc -O listen.swift -o listen \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist 2>/dev/null
fi
exec .venv/bin/python server.py
