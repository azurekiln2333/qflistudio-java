#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/toolchain.env"
flags=(--target="${triple}28" "--sysroot=$sysroot"
  "-resource-dir=$resource" --rtlib=compiler-rt -fuse-ld=lld)
if [[ $(basename "$0") == *++ ]]; then
  exec "$host_cxx" "${flags[@]}" -stdlib=libc++ "$@"
fi
exec "$host_cc" "${flags[@]}" "$@"
