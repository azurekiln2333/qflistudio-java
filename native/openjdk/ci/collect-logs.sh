#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

python3 - "$work" "$logs" <<'PY'
from pathlib import Path
import sys

work, logs = map(Path, sys.argv[1:])
limit = 8 * 1024 * 1024
# Keep bounded diagnostics instead of uploading the source/object tree.
for pattern in ('source/build/*/configure.log', 'source/build/*/config.log',
                'source/build/*/build.log', 'source/build/*/build.log.old',
                'alsa/config.log', 'libffi/config.log'):
    for source in work.glob(pattern):
        if source.is_file():
            target = logs / str(source.relative_to(work)).replace('/', '_').replace('\\', '_')
            with source.open('rb') as stream:
                stream.seek(max(0, source.stat().st_size - limit))
                target.write_bytes(stream.read())
for target in logs.glob('*.log'):
    if target.stat().st_size > limit:
        with target.open('rb') as stream:
            stream.seek(-limit, 2)
            tail = stream.read()
        target.write_bytes(b'[Only the last 8 MiB are retained.]\n' + tail)
PY
df -h "$RUNNER_TEMP" > "$logs/disk.txt"
free -h > "$logs/memory.txt"
