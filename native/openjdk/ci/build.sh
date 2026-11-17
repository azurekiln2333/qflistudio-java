#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
: "${NATIVE_SDK_DIR:?Run prepare.sh first}"

if [[ $NATIVE_PLATFORM == android ]]; then
  bash "$ci_dir/../android/build.sh" \
    --ndk-dir "$NATIVE_SDK_DIR" --boot-jdk "$boot_jdk" --abi "$NATIVE_ABI" \
    --work-dir "$work" --cache-dir "$cache" --jobs "$jobs"
else
  bash "$ci_dir/../ohos/build.sh" \
    --sdk-dir "$NATIVE_SDK_DIR" --boot-jdk "$boot_jdk" --header-dir /usr/include \
    --arch "$cpu" --work-dir "$work" --cache-dir "$cache" --jobs "$jobs"
fi
