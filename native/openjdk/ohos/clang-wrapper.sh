#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/toolchain.env"
flags=("--target=$arch-linux-ohos" "--sysroot=$sdk/sysroot"
  "-resource-dir=$sdk/llvm/lib/clang/15.0.4")
linking=true
for arg in "$@"; do
  case "$arg" in -c|-E|-S|--version|-dumpversion|-dumpmachine) linking=false;; esac
done
if $linking; then flags+=(-fuse-ld=lld "-L$sdk/llvm/lib/$arch-linux-ohos"); fi
if [[ $(basename "$0") == *++ ]]; then
  exec "$host_cxx" "${flags[@]}" -isystem "$sdk/llvm/include/c++/v1" -stdlib=libc++ "$@"
fi
exec "$host_cc" "${flags[@]}" "$@"
