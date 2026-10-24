#!/usr/bin/env bash
# Talk, it opens the app. ./open.sh [--mode hard|jev|hybrid] [--dry]
set -uo pipefail
cd "$(dirname "$0")"
if [ ! -x ./listen ] || [ listen.swift -nt ./listen ]; then
  swiftc -O listen.swift -o listen \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist 2>/dev/null
fi
./listen | .venv/bin/python launcher.py "$@"
