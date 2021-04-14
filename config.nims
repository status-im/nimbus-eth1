if defined(release):
  switch("nimcache", "nimcache/release/$projectName")
else:
  switch("nimcache", "nimcache/debug/$projectName")

if defined(windows):
  # disable timestamps in Windows PE headers - https://wiki.debian.org/ReproducibleBuilds/TimestampsInPEBinaries
  switch("passL", "-Wl,--no-insert-timestamp")
  # increase stack size
  switch("passL", "-Wl,--stack,8388608")
  # https://github.com/nim-lang/Nim/issues/4057
  --tlsEmulation:off
  if defined(i386):
    # set the IMAGE_FILE_LARGE_ADDRESS_AWARE flag so we can use PAE, if enabled, and access more than 2 GiB of RAM
    switch("passL", "-Wl,--large-address-aware")

# This helps especially for 32-bit x86, which sans SSE2 and newer instructions
# requires quite roundabout code generation for cryptography, and other 64-bit
# and larger arithmetic use cases, along with register starvation issues. When
# engineering a more portable binary release, this should be tweaked but still
# use at least -msse2 or -msse3.
if defined(disableMarchNative):
  if defined(i386) or defined(amd64):
    switch("passC", "-msse3")
    switch("passL", "-msse3")
else:
  switch("passC", "-march=native")
  switch("passL", "-march=native")
  if defined(windows):
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=65782
    # ("-fno-asynchronous-unwind-tables" breaks Nim's exception raising, sometimes)
    switch("passC", "-mno-avx512f")
    switch("passL", "-mno-avx512f")

# omitting frame pointers in nim breaks the GC
# https://github.com/nim-lang/Nim/issues/10625
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

# the default open files limit is too low on macOS (512), breaking the
# "--debugger:native" build. It can be increased with `ulimit -n 1024`.
if not defined(macosx):
  # add debugging symbols and original files and line numbers
  --debugger:native
  if not (defined(windows) and defined(i386)) and not defined(disable_libbacktrace):
    # light-weight stack traces using libbacktrace and libunwind
    --define:nimStackTraceOverride
    switch("import", "libbacktrace")

--define:nimOldCaseObjects # https://github.com/status-im/nim-confutils/issues/9
# libnimbus.so needs position-independent code
switch("passC", "-fPIC")

# The compiler doth protest too much, methinks, about all these cases where it can't
# do its (N)RVO pass: https://github.com/nim-lang/RFCs/issues/230
switch("warning", "ObservableStores:off")

# Too many false positives for "Warning: method has lock level <unknown>, but another method has 0 [LockLevel]"
switch("warning", "LockLevel:off")

