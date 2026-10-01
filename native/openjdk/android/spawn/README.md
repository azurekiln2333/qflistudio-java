# Android Spawn Compatibility Library

These unmodified files are retained from termux/termux-packages commit
`d0f94da1e578a0c9550a84d408bc8ed0003882ec`, under
`packages/libandroid-spawn`. The upstream implementation originates in
Android's Bionic and uses the BSD license in LICENSE.

The pinned binary package has 4 KiB LOAD alignment. build.sh rebuilds the
same upstream library with 16 KiB linker alignment for each target ABI.
The matching header preserves the existing spawn ABI used by OpenJDK.

| File | SHA-256 |
| --- | --- |
| posix_spawn.cpp | 5267405b1b14fcbe885bd815d9bd5dde94144dc90b319d6f4be17e47f43bcad3 |
| posix_spawn.h | 5cc27528237cf17727709eaab624f20878b71013b2eb265e3a6e6dae1e4294a0 |
| LICENSE | 511ce23b36ca7dd3858570d8ee3054ceed18e12d284f96661d030a82590a5954 |
