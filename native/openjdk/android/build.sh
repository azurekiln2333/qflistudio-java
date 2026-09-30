#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source_sha=ba3ac4b9d7f2c050f46ddcec39b4258660a3f09836f5a71617fd3f7311d06c0b
termux_commit=d0f94da1e578a0c9550a84d408bc8ed0003882ec
app_id=com.azurekiln.qfli.jvmx
jobs=8
configure_only=false
ndk_dir=
work_dir=
cache_dir=
boot_jdk=

usage() {
  printf '%s\n' 'Usage: bash build.sh --ndk-dir PATH --work-dir PATH --boot-jdk PATH' \
    '                     [--cache-dir PATH] [--app-id ID] [--jobs N] [--configure-only]'
}

while (($#)); do
  case "$1" in
    --ndk-dir|--work-dir|--cache-dir|--boot-jdk|--app-id|--jobs)
      (($# >= 2)) || { usage >&2; exit 2; }
      key=$1; value=$2; shift 2
      case "$key" in
        --ndk-dir) ndk_dir=$value;; --work-dir) work_dir=$value;;
        --cache-dir) cache_dir=$value;; --boot-jdk) boot_jdk=$value;;
        --app-id) app_id=$value;; --jobs) jobs=$value;;
      esac;;
    --configure-only) configure_only=true; shift;;
    --help) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
[[ -n $ndk_dir && -n $work_dir && -n $boot_jdk ]] || { usage >&2; exit 2; }
[[ $app_id =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$ && $jobs =~ ^[1-9][0-9]*$ ]] || exit 2
[[ ! $work_dir =~ [[:space:]] && ! $ndk_dir =~ [[:space:]] ]] || {
  printf '%s\n' 'OpenJDK build and NDK paths must not contain whitespace.' >&2; exit 2;
}
ndk_dir=$(cd "$ndk_dir" && pwd)
boot_jdk=$(cd "$boot_jdk" && pwd)
mkdir -p "$work_dir" "${cache_dir:=$work_dir/cache}"
work_dir=$(cd "$work_dir" && pwd)
cache_dir=$(cd "$cache_dir" && pwd)

for tool in clang clang++ curl tar patch dpkg-deb sha256sum sha1sum make file readelf zip unzip; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 1; }
done
prebuilt=$ndk_dir/toolchains/llvm/prebuilt/linux-x86_64
[[ -d $prebuilt ]] || prebuilt=$ndk_dir/toolchains/llvm/prebuilt/windows-x86_64
sysroot=$prebuilt/sysroot
resource=$prebuilt/lib/clang/18
[[ -f $sysroot/usr/lib/aarch64-linux-android/28/libc.so && -d $resource ]] || {
  printf '%s\n' 'This build requires the Clang 18 resource files from Android NDK 27.' >&2; exit 1;
}
[[ $(clang -dumpversion) == 18.* ]] || {
  printf '%s\n' 'Host Clang 18 is required to match NDK compiler-rt.' >&2; exit 1;
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
patch_dir=$cache_dir/termux-openjdk17-patches
mkdir -p "$patch_dir"
while read -r sha name; do
  [[ -n $sha && $sha != \#* ]] || continue
  target=$patch_dir/$name
  if [[ ! -f $target ]]; then
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 25 --max-time 120 \
      --output "$target.part" "https://raw.githubusercontent.com/termux/termux-packages/$termux_commit/packages/openjdk-17/$name"
    mv "$target.part" "$target"
  fi
  size=$(wc -c < "$target")
  actual=$({ printf 'blob %s\0' "$size"; cat "$target"; } | sha1sum | cut -d ' ' -f1)
  [[ $actual == "$sha" ]] || { printf 'Patch checksum mismatch: %s\n' "$name" >&2; exit 1; }
done < "$here/termux-patches.lock"

deps=$work_dir/dependencies/data/data/com.termux/files/usr
while read -r sha name path; do
  [[ -n $sha && $sha != \#* ]] || continue
  download "https://packages.termux.dev/apt/termux-main/pool/main/$path/$name" "$cache_dir/$name" "$sha"
  dpkg-deb -x "$cache_dir/$name" "$work_dir/dependencies"
done < "$here/dependencies.lock"
for lib in pthread rt; do
  [[ -e $deps/lib/lib$lib.so ]] || ln -s "$sysroot/usr/lib/aarch64-linux-android/28/libc.so" "$deps/lib/lib$lib.so"
done

src=$work_dir/source
prefix=/data/data/$app_id/files/usr
stamp="$source_sha:$app_id:$(sha256sum "$here/termux-patches.lock" "$here/headless-fontmanager.patch" "$here/../app-layout.patch" | sha256sum | cut -d ' ' -f1)"
if [[ -d $src ]]; then
  [[ -f $src/.qfli-prepared && $(< "$src/.qfli-prepared") == "$stamp" ]] || {
    printf 'Source directory has different inputs; choose a new work directory: %s\n' "$src" >&2; exit 1;
  }
else
  mkdir -p "$src"
  tar -xzf "$archive" -C "$src" --strip-components=1
  for patch_file in "$patch_dir"/*.patch; do
    sed "s|@TERMUX_PREFIX@|$prefix|g" "$patch_file" | patch --directory="$src" -p1 --batch
  done
  tmp_path=$prefix/tmp
  sed -e "s|@TERMUX_PREFIX@|$prefix|g" -e "s|@TERMUX_TMPDIR_PATH_LENGTH@|${#tmp_path}|g" \
    "$patch_dir/tmpdir-path-length.diff" | patch --directory="$src" -p1 --batch
  patch --directory="$src" -p1 --batch < "$here/headless-fontmanager.patch"
  patch --directory="$src" -p1 --batch < "$here/../app-layout.patch"
  printf '%s\n' "$stamp" > "$src/.qfli-prepared"
fi

toolchain=$work_dir/toolchain
mkdir -p "$toolchain"
cp "$here/clang-wrapper.sh" "$toolchain/android-clang"
cp "$here/clang-wrapper.sh" "$toolchain/android-clang++"
chmod 755 "$toolchain/android-clang" "$toolchain/android-clang++"
printf 'host_cc=%q\nhost_cxx=%q\nsysroot=%q\nresource=%q\n' \
  "$(command -v clang)" "$(command -v clang++)" "$sysroot" "$resource" > "$toolchain/toolchain.env"
llvm_args=()
for pair in AR:ar NM:nm OBJCOPY:objcopy OBJDUMP:objdump STRIP:strip CXXFILT:cxxfilt; do
  name=${pair%%:*}; executable=$(command -v "llvm-${pair#*:}-18")
  llvm_args+=("$name=$executable")
done

cd "$src"
CC=$toolchain/android-clang CXX=$toolchain/android-clang++ bash configure \
  --build=x86_64-pc-linux-gnu --host=aarch64-unknown-linux-gnu --target=aarch64-unknown-linux-gnu \
  --disable-precompiled-headers --disable-warnings-as-errors --enable-headless-only \
  --with-jvm-variants=server --with-debug-level=release --with-toolchain-type=clang \
  "--with-boot-jdk=$boot_jdk" "--with-sysroot=$sysroot" \
  --with-freetype=bundled --with-libjpeg=bundled --with-giflib=bundled --with-libpng=bundled --with-lcms=bundled \
  "--with-cups=$deps" "--with-cups-include=$deps/include" \
  "--with-fontconfig=$deps" "--with-fontconfig-include=$deps/include" \
  "--with-alsa=$deps" "--with-alsa-include=$deps/include/alsa" "--with-alsa-lib=$deps/lib" \
  "--with-extra-cflags=-I$deps/include -D__ANDROID__=1 -D__TERMUX__=1 -DLE_STANDALONE" \
  "--with-extra-cxxflags=-I$deps/include -D__ANDROID__=1 -D__TERMUX__=1 -DLE_STANDALONE" \
  "--with-extra-ldflags=-L$deps/lib -fuse-ld=lld -landroid-shmem -landroid-spawn -liconv" \
  "--with-jobs=$jobs" "${llvm_args[@]}" \
  "BUILD_CC=$(command -v clang)" "BUILD_CXX=$(command -v clang++)" \
  "BUILD_AR=$(command -v llvm-ar-18)" "BUILD_NM=$(command -v llvm-nm-18)" \
  "BUILD_OBJCOPY=$(command -v llvm-objcopy-18)" "BUILD_STRIP=$(command -v llvm-strip-18)"
if $configure_only; then exit 0; fi
make images "JOBS=$jobs"
image=$src/build/linux-aarch64-server-release/images/jdk
for lib in libandroid-shmem.so libandroid-spawn.so libandroid-sysv-semaphore.so libiconv.so libasound.so; do
  cp -L "$deps/lib/$lib" "$image/lib/$lib"
done
cp "$sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$image/lib/"
for tool in java javac jar javap jshell; do test -x "$image/bin/$tool"; done
readelf -l "$image/bin/java" | grep '/system/bin/linker64'
printf 'Android ARM64 JDK image: %s\n' "$image"
