#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

image=${1:-$(image_path)}
mirror=$RUNNER_TEMP/native-image
stem=openjdk-$NATIVE_PLATFORM-$NATIVE_ABI
mkdir -p "$out" "$mirror"
for tool in java javac jar javap jshell; do test -f "$image/bin/$tool"; done
test -f "$image/lib/modules"
test -d "$image/legal"

# Export real files so Windows and PowerShell traverse every legal notice.
tar --dereference --hard-dereference --exclude='*.debuginfo' --exclude='./lib/src.zip' \
  -cf - -C "$image" . | tar -xf - -C "$mirror"
python3 "$ci_dir/notices.py" "$mirror" "$work" "$cache" "$NATIVE_PLATFORM"
tar -czf "$out/$stem-image.tar.gz" -C "$mirror" .
pwsh -NoProfile -File "$ci_dir/../stage.ps1" \
  -Platform "$NATIVE_PLATFORM" -Abi "$NATIVE_ABI" -Image "$mirror"

paths=("native/build/$NATIVE_PLATFORM/jniLibs/$NATIVE_ABI"
  "native/build/$NATIVE_PLATFORM/assets/jdk-$NATIVE_ABI.zip"
  "native/build/$NATIVE_PLATFORM/assets/jdk-$NATIVE_ABI.json")
if [[ $NATIVE_PLATFORM == ohos ]]; then
  paths+=("ohos/entry/libs/$NATIVE_ABI"
    "ohos/entry/src/main/resources/rawfile/jdk-$NATIVE_ABI.zip"
    "ohos/entry/src/main/resources/rawfile/jdk-$NATIVE_ABI.json")
fi
tar -czf "$out/$stem-staged.tar.gz" -C "$repo" "${paths[@]}"
python3 - "$repo" "$out" "$image" "$jobs" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

repo, output, image = map(Path, sys.argv[1:4])
platform = os.environ['NATIVE_PLATFORM']
recipe = repo / 'native/openjdk' / platform / 'build.sh'
manifest = json.loads((repo / 'native/openjdk/ci/inputs.lock.json').read_text())
provenance = {
    'version': 1,
    'commit': os.environ['GITHUB_SHA'],
    'repository': os.environ['GITHUB_REPOSITORY'],
    'run': f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
    'platform': platform,
    'abi': os.environ['NATIVE_ABI'],
    'jobs': int(sys.argv[4]),
    'compiler': subprocess.check_output(['clang', '--version'], text=True).strip(),
    'boot_jdk': subprocess.check_output(['/usr/lib/jvm/java-17-openjdk-amd64/bin/java', '-version'], stderr=subprocess.STDOUT, text=True).strip(),
    'openjdk_source_sha256': re.search(r'^source_sha=([a-f0-9]+)$', recipe.read_text(), re.M)[1],
    'jdk_release': (image / 'release').read_text(),
    'recipe_sha256': hashlib.sha256(recipe.read_bytes()).hexdigest(),
    'retained_inputs': manifest,
    'device_runtime_verified': False,
}
if platform == 'android':
    provenance['ndk_version'] = '27.0.12077973'
else:
    provenance['sdk'] = {'url': os.environ['OHOS_SDK_URL'], 'sha256': os.environ['OHOS_SDK_SHA256']}
(output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
PY
(
  cd "$out"
  sha256sum "$stem-image.tar.gz" "$stem-staged.tar.gz" provenance.json > SHA256SUMS
  sha256sum --check SHA256SUMS
)
{
  printf '### %s / %s\n\n' "$NATIVE_PLATFORM" "$NATIVE_ABI"
  printf 'Native JDK compilation and staging passed. Device execution was not tested.\n\n'
  printf 'Download the `native-%s-%s-%s` artifact below.\n\n' "$NATIVE_PLATFORM" "$NATIVE_ABI" "$GITHUB_SHA"
  printf -- '- `%s-image.tar.gz`: portable native JDK image.\n' "$stem"
  printf -- '- `%s-staged.tar.gz`: app inputs; extract at the repository root.\n' "$stem"
  printf -- '- `SHA256SUMS` and `provenance.json`: integrity and input records.\n'
} >> "$GITHUB_STEP_SUMMARY"
