#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  clang-18 llvm-18 lld-18 build-essential autoconf file curl zip unzip \
  zlib1g-dev openjdk-17-jdk libcups2-dev libfontconfig1-dev libx11-dev
clang --version
"$boot_jdk/bin/java" -version
df -h "$RUNNER_TEMP"

if [[ $NATIVE_PLATFORM == android ]]; then
  # Seed the recipe's cache with exact locked bytes; the recipe rechecks each hash.
  mapfile -t retained < <(python3 - "$ci_dir/inputs.lock.json" <<'PY'
import json
import sys
entry = json.load(open(sys.argv[1], encoding='utf-8'))['dependencies']
for key in ('url', 'filename', 'sha256'):
    print(entry[key])
PY
  )
  [[ ${#retained[@]} == 3 ]]
  download_verified "${retained[0]}" "$cache/${retained[1]}" "${retained[2]}"
  tar -xzf "$cache/${retained[1]}" -C "$cache"
  for lock in "$ci_dir/../android/dependencies.lock" "$ci_dir/../android/dependencies-x86_64.lock"; do
    while read -r checksum filename _; do
      [[ -n $checksum && $checksum != \#* ]] || continue
      printf '%s  %s\n' "$checksum" "$cache/$filename" | sha256sum --check
    done < "$lock"
  done
  sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:?Android SDK is missing}}
  "$sdk_root/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$sdk_root" 'ndk;27.0.12077973'
  printf 'NATIVE_SDK_DIR=%s\n' "$sdk_root/ndk/27.0.12077973" >> "$GITHUB_ENV"
else
  sdk_root=$RUNNER_TEMP/ohos-sdk
  sdk_archive=$RUNNER_TEMP/ohos-sdk-public.tar.gz
  sdk_url=https://repo.huaweicloud.com/openharmony/os/6.0-Release/ohos-sdk-windows_linux-public.tar.gz
  sdk_sha=a315834ac133625efc912bd078f3e2b2550868d04aef1b5aa4f9679c8b3c9d8e
  download_verified "$sdk_url" "$sdk_archive" "$sdk_sha"
  mkdir -p "$sdk_root/components"
  tar -xzf "$sdk_archive" -C "$sdk_root/components" --wildcards 'linux/native-linux-x64-*.zip'
  # Reclaim the large multi-platform archive before unpacking the native SDK.
  rm -f -- "$sdk_archive"
  mapfile -t components < <(find "$sdk_root/components" -type f -name 'native-linux-x64-*.zip')
  [[ ${#components[@]} == 1 ]] || { printf '%s\n' 'Expected one Linux native SDK component.' >&2; exit 1; }
  unzip -q "${components[0]}" -d "$sdk_root"
  rm -f -- "${components[0]}"
  sdk=$sdk_root/native
  for directory in llvm/lib/clang/15.0.4 llvm/include/c++/v1 "llvm/lib/$cpu-linux-ohos"; do
    [[ -d $sdk/$directory ]] || { printf 'Missing SDK resource: %s\n' "$directory" >&2; exit 1; }
  done
  [[ -f $sdk/sysroot/usr/lib/$cpu-linux-ohos/libc.so ]]
  printf 'NATIVE_SDK_DIR=%s\n' "$sdk" >> "$GITHUB_ENV"
  printf 'OHOS_SDK_URL=%s\nOHOS_SDK_SHA256=%s\n' "$sdk_url" "$sdk_sha" >> "$GITHUB_ENV"
fi
