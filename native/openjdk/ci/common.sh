#!/usr/bin/env bash
# Shared paths for the GitHub-hosted native build scripts.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must name the runner scratch directory}"
: "${NATIVE_PLATFORM:?Select android or ohos}"
: "${NATIVE_ABI:?Select arm64-v8a or x86_64}"
case "$NATIVE_PLATFORM" in android|ohos) ;; *) exit 2;; esac
case "$NATIVE_ABI" in
  arm64-v8a) cpu=aarch64;;
  x86_64) cpu=x86_64;;
  *) exit 2;;
esac
ci_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$ci_dir/../../.." && pwd)
cache=$RUNNER_TEMP/native-downloads
work=$RUNNER_TEMP/native-work
out=$RUNNER_TEMP/native-artifacts
logs=$RUNNER_TEMP/native-logs
boot_jdk=/usr/lib/jvm/java-17-openjdk-amd64
jobs=$(nproc)
((jobs <= 4)) || jobs=4
export PATH="/usr/lib/llvm-18/bin:$PATH"
mkdir -p "$cache" "$logs"

download_verified() {
  local url=$1 destination=$2 checksum=$3
  if [[ -f $destination ]] && [[ $(sha256sum "$destination" | cut -d ' ' -f1) == "$checksum" ]]; then
    return
  fi
  curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
    --max-time 1800 --output "$destination.part" "$url"
  printf '%s  %s\n' "$checksum" "$destination.part" | sha256sum --check
  mv "$destination.part" "$destination"
}

image_path() {
  if [[ $NATIVE_PLATFORM == android ]]; then
    printf '%s/source/build/linux-%s-server-release/images/jdk\n' "$work" "$cpu"
  else
    printf '%s/source/build/ohos-%s-zero-release/images/jdk\n' "$work" "$cpu"
  fi
}
