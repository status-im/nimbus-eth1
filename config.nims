import strutils

--noNimblePath

if getEnv("NIMBUS_BUILD_SYSTEM") == "yes" and
   system.fileExists("nimbus-build-system.paths"):
  include "nimbus-build-system.paths"

if defined(release):
  switch("nimcache", "nimcache/release/$projectName")
else:
  switch("nimcache", "nimcache/debug/$projectName")

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

  # Avoid some rare stack corruption while using exceptions with a SEH-enabled
  # toolchain: https://github.com/status-im/nimbus-eth2/issues/3121
  switch("define", "nimRawSetjmp")

# This helps especially for 32-bit x86, which sans SSE2 and newer instructions
# requires quite roundabout code generation for cryptography, and other 64-bit
# and larger arithmetic use cases, along with register starvation issues. When
# engineering a more portable binary release, this should be tweaked but still
# use at least -msse2 or -msse3.
#
# https://github.com/status-im/nimbus-eth2/blob/stable/docs/cpu_features.md#ssse3-supplemental-sse3
# suggests that SHA256 hashing with SSSE3 is 20% faster than without SSSE3, so
# given its near-ubiquity in the x86 installed base, it renders a distribution
# build more viable on an overall broader range of hardware.
#
if defined(disableMarchNative):
  if defined(i386) or defined(amd64):
    if defined(macosx):
      # https://support.apple.com/kb/SP777
      # "macOS Mojave - Technical Specifications": EOL as of 2021-10 so macOS
      # users on pre-Nehalem must be running either some Hackintosh, or using
      # an unsupported macOS version beyond that most recently EOL'd. Nehalem
      # supports instruction set extensions through SSE4.2 and POPCNT.
      switch("passC", "-march=nehalem")
      switch("passL", "-march=nehalem")
    else:
      switch("passC", "-mssse3")
      switch("passL", "-mssse3")
elif defined(macosx) and defined(arm64):
  # Apple's Clang can't handle "-march=native" on M1: https://github.com/status-im/nimbus-eth2/issues/2758
  switch("passC", "-mcpu=apple-a14")
  switch("passL", "-mcpu=apple-a14")
else:
  switch("passC", "-march=native")
  switch("passL", "-march=native")
  if defined(windows):
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=65782
    # ("-fno-asynchronous-unwind-tables" breaks Nim's exception raising, sometimes)
    switch("passC", "-mno-avx512f")
    switch("passL", "-mno-avx512f")

# Omitting frame pointers in nim breaks the GC:
# https://github.com/nim-lang/Nim/issues/10625
if not defined(windows):
  # ...except on Windows where the Nim bug doesn't manifest and the option
  # crashes GCC in some Mingw-w64 versions:
  # https://sourceforge.net/p/mingw-w64/bugs/880/
  # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=86593
  switch("passC", "-fno-omit-frame-pointer")
  switch("passL", "-fno-omit-frame-pointer")

--threads:on
--opt:speed
--excessiveStackTrace:on
# enable metric collection
--define:metrics
# for heap-usage-by-instance-type metrics and object base-type strings
--define:nimTypeNames

switch("define", "withoutPCRE")

when not defined(disable_libbacktrace):
  --define:nimStackTraceOverride
  switch("import", "libbacktrace")
else:
  --stacktrace:on
  --linetrace:on

var canEnableDebuggingSymbols = true
if defined(macosx):
  # The default open files limit is too low on macOS (512), breaking the
  # "--debugger:native" build. It can be increased with `ulimit -n 1024`.
  let openFilesLimitTarget = 1024
  var openFilesLimit = 0
  try:
    openFilesLimit = staticExec("ulimit -n").strip(chars = Whitespace + Newlines).parseInt()
    if openFilesLimit < openFilesLimitTarget:
      echo "Open files limit too low to enable debugging symbols and lightweight stack traces."
      echo "Increase it with \"ulimit -n " & $openFilesLimitTarget & "\""
      canEnableDebuggingSymbols = false
  except:
    echo "ulimit error"
# We ignore this resource limit on Windows, where a default `ulimit -n` of 256
# in Git Bash is apparently ignored by the OS, and on Linux where the default of
# 1024 is good enough for us.

if canEnableDebuggingSymbols:
  # add debugging symbols and original files and line numbers
  --debugger:native

--define:nimOldCaseObjects # https://github.com/status-im/nim-confutils/issues/9

# `switch("warning[CaseTransition]", "off")` fails with "Error: invalid command line option: '--warning[CaseTransition]'"
switch("warning", "CaseTransition:off")

# The compiler doth protest too much, methinks, about all these cases where it can't
# do its (N)RVO pass: https://github.com/nim-lang/RFCs/issues/230
switch("warning", "ObservableStores:off")

# Too many false positives for "Warning: method has lock level <unknown>, but another method has 0 [LockLevel]"
switch("warning", "LockLevel:off")

# nimbus-eth1 doesn't use 'news' nor ws client, only websock server. set the backend package to websock.
switch("define", "json_rpc_websocket_package:websock")

if defined(windows) and defined(i386):
  # avoid undefined reference to 'sqrx_mont_384x' when compiling in 32 bit mode
  # without actually using __BLST_PORTABLE__ or __BLST_NO_ASM__
  switch("define", "BLS_FORCE_BACKEND:miracl")
