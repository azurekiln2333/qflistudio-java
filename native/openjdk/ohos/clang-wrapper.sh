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
  cxx_headers=$sdk/llvm/include/libcxx-ohos/include/c++/v1
  # Prefer the OHOS tree whose ABI matches the target libc++. Older SDKs can
  # provide only a complete generic tree. Combining both full trees breaks
  # libc++ include_next wrappers such as stddef.h.
  if [[ ! -f $cxx_headers/__config_site ]]; then
    cxx_headers=$sdk/llvm/include/c++/v1
  fi
  [[ -f $cxx_headers/__config_site ]] || {
    printf '%s\n' 'Missing OHOS libc++ __config_site.' >&2; exit 1;
  }
  exec "$host_cxx" "${flags[@]}" -isystem "$cxx_headers" -stdlib=libc++ "$@"
fi
exec "$host_cc" "${flags[@]}" "$@"
