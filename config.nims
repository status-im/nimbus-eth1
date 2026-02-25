# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import strutils

const currentDir = currentSourcePath()[0 .. ^(len("config.nims") + 1)]

if getEnv("NIMBUS_BUILD_SYSTEM") == "yes" and
   # BEWARE
   # In Nim 1.6, config files are evaluated with a working directory
   # matching where the Nim command was invocated. This means that we
   # must do all file existance checks with full absolute paths:
   system.fileExists(currentDir & "nimbus-build-system.paths"):
  include "nimbus-build-system.paths"

const nimCachePathOverride {.strdefine.} = ""
when nimCachePathOverride == "":
  when defined(release):
    let nimCachePath = "nimcache/release/" & projectName()
  else:
    let nimCachePath = "nimcache/debug/" & projectName()
else:
  let nimCachePath = nimCachePathOverride
switch("nimcache", nimCachePath)

# Hidden visibility allows for better position-independent codegen - it also
# resolves a build issue in BLST where otherwise private symbols would require
# an unsupported relocation on PIE-enabled distros such as ubuntu - BLST itself
# solves this via a linker script which is messy
switch("passC", "-fvisibility=hidden")

if defined(windows):
  # disable timestamps in Windows PE headers - https://wiki.debian.org/ReproducibleBuilds/TimestampsInPEBinaries
  switch("passL", "-Wl,--no-insert-timestamp")
  # increase stack size, unless something else is setting the stack size
  if not defined(windowsNoSetStack):
    switch("passL", "-Wl,--stack,8388608")
  # https://github.com/nim-lang/Nim/issues/4057
  --tlsEmulation:off
  if defined(i386):
    # set the IMAGE_FILE_LARGE_ADDRESS_AWARE flag so we can use PAE, if enabled, and access more than 2 GiB of RAM
    switch("passL", "-Wl,--large-address-aware")

  # Colors are disabled for Windows, see issue:
  # https://github.com/status-im/nim-chronicles/issues/130
  switch("define", "chronicles_colors=off")

  # Avoid some rare stack corruption while using exceptions with a SEH-enabled
  # toolchain: https://github.com/status-im/nimbus-eth2/issues/3121
  switch("define", "nimRawSetjmp")

# omitting frame pointers in nim breaks the GC
# https://github.com/nim-lang/Nim/issues/10625
switch("passC", "-fno-omit-frame-pointer")
switch("passL", "-fno-omit-frame-pointer")

--threads:on
--mm:orc
--excessiveStackTrace:on

# Workaround for v2.2.8 regression; remove with v2.2.10
# https://github.com/nim-lang/Nim/pull/25343
--mangle:cpp

switch("define", "nim_compiler_path=" & currentDir & "env.sh nim")
switch("define", "withoutPCRE")

# nim-kzg shipping their own blst, nimbus-eth1 too.
# disable nim-kzg's blst
switch("define", "kzgExternalBlst")

# We lock down rocksdb to a particular version
# TODO self-build rocksdb dll on windows
when not defined(use_system_rocksdb) and not defined(windows):

  # use the C++ linker profile because it's a C++ library
  when defined(macosx):
    switch("clang.linkerexe", "clang++")
  else:
    switch("gcc.linkerexe", "g++")

# This applies per-file compiler flags to C files
# which do not support {.localPassC: "-fno-lto".}
# Unfortunately this is filename based instead of path-based
# Assumes GCC

# Secp256k1
# -fomit-frame-pointer for:
# https://github.com/status-im/nimbus-eth1/issues/2127
# https://github.com/status-im/nimbus-eth2/issues/6324
put("secp256k1.always", "-fno-lto -fomit-frame-pointer")
