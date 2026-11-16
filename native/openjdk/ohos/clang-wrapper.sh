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
  flags+=(-isystem "$sdk/llvm/include/c++/v1")
  # Public SDKs keep __config_site in a target-specific directory. Preserve the
  # generic include first for SDKs that already carry their configuration there.
  target_headers=$sdk/llvm/include/$arch-linux-ohos/c++/v1
  if [[ -d $target_headers ]]; then flags+=(-isystem "$target_headers"); fi
  exec "$host_cxx" "${flags[@]}" -stdlib=libc++ "$@"
fi
exec "$host_cc" "${flags[@]}" "$@"
