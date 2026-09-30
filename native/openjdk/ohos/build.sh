#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source_sha=ba3ac4b9d7f2c050f46ddcec39b4258660a3f09836f5a71617fd3f7311d06c0b
alsa_sha=f740db7f488255944ffd4428416ee3390a96742856916433df468c281436480e
ffi_sha=bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b
termux_commit=d0f94da1e578a0c9550a84d408bc8ed0003882ec
arch=x86_64
jobs=8
sdk=
work_dir=
cache_dir=
boot_jdk=
header_dir=
configure_only=false

usage() {
  printf '%s\n' 'Usage: bash build.sh --sdk-dir PATH --work-dir PATH --boot-jdk PATH' \
    '                     --header-dir PATH [--arch x86_64|aarch64]' \
    '                     [--cache-dir PATH] [--jobs N] [--configure-only]'
}

while (($#)); do
  case "$1" in
    --sdk-dir|--work-dir|--cache-dir|--boot-jdk|--header-dir|--arch|--jobs)
      (($# >= 2)) || { usage >&2; exit 2; }
      key=$1; value=$2; shift 2
      case "$key" in
        --sdk-dir) sdk=$value;; --work-dir) work_dir=$value;;
        --cache-dir) cache_dir=$value;; --boot-jdk) boot_jdk=$value;;
        --header-dir) header_dir=$value;; --arch) arch=$value;; --jobs) jobs=$value;;
      esac;;
    --configure-only) configure_only=true; shift;;
    --help) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
[[ -n $sdk && -n $work_dir && -n $boot_jdk && -n $header_dir ]] || { usage >&2; exit 2; }
[[ $arch == x86_64 || $arch == aarch64 ]] || { usage >&2; exit 2; }
[[ $jobs =~ ^[1-9][0-9]*$ ]] || exit 2
[[ ! $sdk =~ [[:space:]] && ! $work_dir =~ [[:space:]] ]] || {
  printf '%s\n' 'OpenJDK build and SDK paths must not contain whitespace.' >&2; exit 2;
}
sdk=$(cd "$sdk" && pwd)
boot_jdk=$(cd "$boot_jdk" && pwd)
header_dir=$(cd "$header_dir" && pwd)
mkdir -p "$work_dir" "${cache_dir:=$work_dir/cache}"
work_dir=$(cd "$work_dir" && pwd)
cache_dir=$(cd "$cache_dir" && pwd)

for tool in clang clang++ curl tar patch sha256sum sha1sum make readelf; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 1; }
done
[[ $(clang -dumpversion) == 18.* && -d $sdk/llvm/lib/clang/15.0.4 && \
  -f $sdk/sysroot/usr/lib/$arch-linux-ohos/libc.so ]] || {
  printf '%s\n' 'Requires host Clang 18 and an OHOS SDK with Clang 15.0.4 target resources.' >&2; exit 1;
}

download() {
  local url=$1 file=$2 sha=$3
  if [[ -f $file ]] && [[ $(sha256sum "$file" | cut -d ' ' -f1) == "$sha" ]]; then return; fi
  curl --fail --location --retry 5 --retry-all-errors --connect-timeout 25 \
    --max-time 900 --output "$file.part" "$url"
  [[ $(sha256sum "$file.part" | cut -d ' ' -f1) == "$sha" ]] || {
    printf 'Checksum mismatch: %s\n' "$file" >&2; exit 1;
  }
  mv "$file.part" "$file"
}

archive=$cache_dir/jdk17u-jdk-17.0.20-ga.tar.gz
download 'https://codeload.github.com/openjdk/jdk17u/tar.gz/refs/tags/jdk-17.0.20-ga' "$archive" "$source_sha"
download 'https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.16.1.tar.bz2' \
  "$cache_dir/alsa-lib-1.2.16.1.tar.bz2" "$alsa_sha"
download 'https://github.com/libffi/libffi/releases/download/v3.4.8/libffi-3.4.8.tar.gz' \
  "$cache_dir/libffi-3.4.8.tar.gz" "$ffi_sha"

patch_dir=$cache_dir/termux-openjdk17-patches
mkdir -p "$patch_dir"
patches=()
while read -r sha name; do
  case "$name" in 0032-*|0033-*|0034-*) ;; *) continue;; esac
  target=$patch_dir/$name
  if [[ ! -f $target ]]; then
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 25 --max-time 120 \
      --output "$target.part" "https://raw.githubusercontent.com/termux/termux-packages/$termux_commit/packages/openjdk-17/$name"
    mv "$target.part" "$target"
  fi
  size=$(wc -c < "$target")
  actual=$({ printf 'blob %s\0' "$size"; cat "$target"; } | sha1sum | cut -d ' ' -f1)
  [[ $actual == "$sha" ]] || { printf 'Patch checksum mismatch: %s\n' "$name" >&2; exit 1; }
  patches+=("$target")
done < "$here/../android/termux-patches.lock"

src=$work_dir/source
stamp="$source_sha:$arch:$(sha256sum "$here/hotspot.patch" "$here/zero-memory.patch" "$here/../app-layout.patch" "$here/app-libraries.patch" "$here/launcher.patch" "$here/child-exit.patch" "${patches[@]}" | sha256sum | cut -d ' ' -f1)"
if [[ -d $src ]]; then
  [[ -f $src/.qfli-prepared && $(< "$src/.qfli-prepared") == "$stamp" ]] || {
    printf 'Source directory has different inputs; choose a new work directory: %s\n' "$src" >&2; exit 1;
  }
else
  mkdir -p "$src"
  tar -xzf "$archive" -C "$src" --strip-components=1
  for patch_file in "${patches[@]}" "$here/hotspot.patch" "$here/zero-memory.patch" "$here/../app-layout.patch" "$here/app-libraries.patch" "$here/launcher.patch" "$here/child-exit.patch"; do
    patch --directory="$src" -p1 --batch < "$patch_file"
  done
  printf '%s\n' "$stamp" > "$src/.qfli-prepared"
fi

toolchain=$work_dir/toolchain
mkdir -p "$toolchain"
cp "$here/clang-wrapper.sh" "$toolchain/ohos-clang"
cp "$here/clang-wrapper.sh" "$toolchain/ohos-clang++"
chmod 755 "$toolchain/ohos-clang" "$toolchain/ohos-clang++"
printf 'host_cc=%q\nhost_cxx=%q\nsdk=%q\narch=%q\n' \
  "$(command -v clang)" "$(command -v clang++)" "$sdk" "$arch" > "$toolchain/toolchain.env"
export CC=$toolchain/ohos-clang CXX=$toolchain/ohos-clang++ AR=llvm-ar-18 RANLIB=llvm-ranlib-18
deps=$work_dir/dependencies
mkdir -p "$deps/include"
for header in cups fontconfig X11; do
  [[ -d $header_dir/$header ]] || { printf 'Missing headers: %s\n' "$header" >&2; exit 1; }
  cp -a "$header_dir/$header" "$deps/include/"
done

alsa=$work_dir/alsa
ffi=$work_dir/libffi
mkdir -p "$alsa" "$ffi"
tar -xjf "$cache_dir/alsa-lib-1.2.16.1.tar.bz2" -C "$alsa" --strip-components=1
tar -xzf "$cache_dir/libffi-3.4.8.tar.gz" -C "$ffi" --strip-components=1
patch --directory="$alsa" -p1 --batch < "$here/alsa-library-name.patch"
patch --directory="$ffi" -p1 --batch < "$here/ffi-library-name.patch"
cd "$alsa"
./configure "--host=$arch-unknown-linux-musl" "--prefix=$deps" \
  --disable-python --disable-ucm --disable-topology --disable-static
make "-j$jobs"
make install
cd "$ffi"
./configure "--host=$arch-unknown-linux-musl" "--prefix=$deps" --disable-static --disable-docs
make "-j$jobs"
make install

llvm_args=()
for pair in AR:ar NM:nm OBJCOPY:objcopy OBJDUMP:objdump STRIP:strip CXXFILT:cxxfilt; do
  name=${pair%%:*}; executable=$(command -v "llvm-${pair#*:}-18")
  llvm_args+=("$name=$executable")
done
conf=ohos-$arch-zero-release
cd "$src"
bash configure --build=x86_64-pc-linux-gnu "--host=$arch-unknown-linux-musl" "--target=$arch-unknown-linux-musl" \
  "--with-conf-name=$conf" \
  --disable-precompiled-headers --disable-warnings-as-errors --enable-headless-only \
  --with-jvm-variants=zero --with-debug-level=release --with-toolchain-type=clang \
  "--with-boot-jdk=$boot_jdk" "--with-build-jdk=$boot_jdk" "--with-sysroot=$sdk/sysroot" "--with-libffi=$deps" \
  --with-freetype=bundled --with-libjpeg=bundled --with-giflib=bundled --with-libpng=bundled --with-lcms=bundled \
  "--with-cups-include=$deps/include" "--with-fontconfig-include=$deps/include" \
  "--with-alsa-include=$deps/include/alsa" "--with-alsa-lib=$deps/lib" \
  "--with-extra-cflags=-I$deps/include" "--with-extra-cxxflags=-I$deps/include" \
  "--with-extra-ldflags=-Wl,--dynamic-linker=/lib/ld-musl-$arch.so.1" \
  "--with-jobs=$jobs" "${llvm_args[@]}" \
  "BUILD_CC=$(command -v clang)" "BUILD_CXX=$(command -v clang++)" \
  "BUILD_AR=$(command -v llvm-ar-18)" "BUILD_NM=$(command -v llvm-nm-18)" \
  "BUILD_OBJCOPY=$(command -v llvm-objcopy-18)" "BUILD_STRIP=$(command -v llvm-strip-18)"
if $configure_only; then exit 0; fi
make "CONF=$conf" images "JOBS=$jobs"
image=$src/build/$conf/images/jdk
cp -L "$deps/lib/libasound.so" "$deps/lib/libffi.so" "$image/lib/"
for tool in java javac jar javap jshell; do test -x "$image/bin/$tool"; done
readelf -l "$image/bin/java" | grep "/lib/ld-musl-$arch.so.1"
printf 'HarmonyOS %s Zero JDK image: %s\n' "$arch" "$image"
