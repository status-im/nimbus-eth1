#
#
#                    NimCrypto
#        (c) Copyright 2018 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This module implements interface to operation system's random number
## generator.
##
## ``Windows`` using BCryptGenRandom (if available),
## CryptGenRandom(PROV_INTEL_SEC) (if available), RtlGenRandom.
##
## RtlGenRandom (available since Windows XP)
## BCryptGenRandom (available since Windows Vista SP1)
## CryptGenRandom(PROV_INTEL_SEC) (only when Intel SandyBridge
## CPU is available).
##
## ``Linux`` using genrandom (if available), `/dev/urandom`.
##
## ``OpenBSD`` using getentropy.
##
## ``NetBSD``, ``FreeBSD``, ``MacOS``, ``Solaris`` using `/dev/urandom`.

{.push raises: [].}

when defined(posix) or defined(emscripten):
  import os, posix

  proc urandomRead(pbytes: pointer, nbytes: int): int =
    var st: Stat
    let fd = posix.open("/dev/urandom", posix.O_RDONLY)
    if fd == -1:
      return -1
    if posix.fstat(fd, st) == -1 or not (S_ISCHR(st.st_mode)):
      discard posix.close(fd)
      return -1

    var res = 0
    while res < nbytes:
      var p = cast[pointer](cast[uint]((pbytes)) + uint(res))
      var bytesRead = posix.read(fd, p, nbytes - res)
      if bytesRead > 0:
        res += bytesRead
      elif bytesRead == 0:
        break
      else:
        if osLastError() != OSErrorCode(EINTR):
          break
    discard posix.close(fd)
    res

# NOTE: critical for emscripten flag to be processed before linux
# because current workarounds for building wasm in Nim include
# defining the OS as linux
when defined(emscripten) or defined(openbsd):
  # Uses getentropy() provided by emscripten (browser and node)
  # with /dev/urandom as fallback. getentropy() is limited to 256
  # bytes per call per POSIX spec, so we loop in chunks.
  # https://github.com/emscripten-core/emscripten/pull/12240
  # openbsd provides getentropy by default
  proc getentropy(
    pbytes: pointer, nbytes: csize_t
  ): cint {.importc: "getentropy", header: "<unistd.h>".}

  proc randomBytes*(pbytes: pointer, nbytes: int): int =
    const maxChunk = 256
    var res = 0
    while res < nbytes:
      # NOTE: pointer arithmetic - appends by incrementing the pbytes pointer
      let p = cast[pointer](cast[uint](pbytes) + uint(res))
      let chunkSize = min(nbytes - res, maxChunk)
      if getentropy(p, csize_t(chunkSize)) == 0:
        res += chunkSize
      else:
        # interrupted, so retry
        if osLastError() == OSErrorCode(EINTR):
          continue

        # getentropy failed so fall back to /dev/urandom
        let p2 = cast[pointer](cast[uint](pbytes) + uint(res))
        let remaining = urandomRead(p2, nbytes - res)
        if remaining == nbytes - res:
          res = nbytes
        break
    res

elif defined(linux):
  when defined(i386):
    const SYS_getrandom = 355
  elif defined(powerpc64) or defined(powerpc64el) or defined(powerpc):
    const SYS_getrandom = 359
  elif defined(arm64):
    const SYS_getrandom = 278
  elif defined(arm):
    const SYS_getrandom = 384
  elif defined(amd64):
    const SYS_getrandom = 318
  elif defined(mips):
    when sizeof(int) == 8:
      const SYS_getrandom = 4000 + 313
    else:
      const SYS_getrandom = 4000 + 353
  else:
    const SYS_getrandom = 0
  const GRND_NONBLOCK = 1

  type SystemRng = ref object of RootRef
    getRandomPresent: bool

  proc syscall(
    number: clong
  ): clong {.
    importc: "syscall",
    header: """#include <unistd.h>
                  #include <sys/syscall.h>""",
    varargs,
    discardable
  .}

  var gSystemRng {.threadvar.}: SystemRng ## System thread global RNG

  proc newSystemRng(): SystemRng =
    var rng = SystemRng()
    if SYS_getrandom != 0:
      var data: int
      rng.getRandomPresent = true
      let res = syscall(SYS_getrandom, addr data, 1, GRND_NONBLOCK)
      if res == -1:
        let err = osLastError()
        if err == OSErrorCode(ENOSYS) or err == OSErrorCode(EPERM):
          rng.getRandomPresent = false
    rng

  proc getSystemRng(): SystemRng =
    if isNil(gSystemRng):
      gSystemRng = newSystemRng()
    gSystemRng

  proc randomBytes*(pbytes: pointer, nbytes: int): int =
    var p: pointer
    let srng = getSystemRng()

    if srng.getRandomPresent:
      var res = 0
      while res < nbytes:
        p = cast[pointer](cast[uint](pbytes) + uint(res))
        let bytesRead = syscall(SYS_getrandom, pbytes, nbytes - res, 0)
        if bytesRead > 0:
          res += bytesRead
        elif bytesRead == 0:
          break
        else:
          if osLastError().int32 != EINTR:
            break

      if res <= 0:
        res = urandomRead(pbytes, nbytes)
      elif res < nbytes:
        p = cast[pointer](cast[uint](pbytes) + uint(res))
        let bytesRead = urandomRead(p, nbytes - res)
        if bytesRead != -1:
          res += bytesRead
      res
    else:
      urandomRead(pbytes, nbytes)

elif defined(windows):
  import os, winlean, dynlib

  const
    VER_GREATER_EQUAL = 3'u8
    VER_MINORVERSION = 0x0000001
    VER_MAJORVERSION = 0x0000002
    VER_SERVICEPACKMINOR = 0x0000010
    VER_SERVICEPACKMAJOR = 0x0000020
    PROV_INTEL_SEC = 22
    INTEL_DEF_PROV = "Intel Hardware Cryptographic Service Provider"
    CRYPT_VERIFYCONTEXT = 0xF0000000'i32
    CRYPT_SILENT = 0x00000040'i32
    BCRYPT_USE_SYSTEM_PREFERRED_RNG = 0x00000002
  type
    OSVERSIONINFOEXW {.final, pure.} = object
      dwOSVersionInfoSize: DWORD
      dwMajorVersion: DWORD
      dwMinorVersion: DWORD
      dwBuildNumber: DWORD
      dwPlatformId: DWORD
      szCSDVersion: array[128, Utf16Char]
      wServicePackMajor: uint16
      wServicePackMinor: uint16
      wSuiteMask: uint16
      wProductType: byte
      wReserved: byte

    HCRYPTPROV = uint

    BCGRMPROC = proc(
      hAlgorithm: pointer, pBuffer: pointer, cBuffer: ULONG, dwFlags: ULONG
    ): LONG {.stdcall, gcsafe, raises: [].}
    QPCPROC = proc(hProcess: Handle, cycleTime: var uint64): WINBOOL {.
      stdcall, gcsafe, raises: []
    .}
    QUITPROC = proc(itime: var uint64) {.stdcall, gcsafe, raises: [].}
    QIPCPROC = proc(bufferLength: var uint32, idleTime: ptr uint64): WINBOOL {.
      stdcall, gcsafe, raises: []
    .}

    SystemRng = ref object of RootRef
      bCryptGenRandom: BCGRMPROC
      queryProcessCycleTime: QPCPROC
      queryUnbiasedInterruptTime: QUITPROC
      queryIdleProcessorCycleTime: QIPCPROC
      coresCount: uint32
      hIntel: HCRYPTPROV

  var gSystemRng {.threadvar.}: SystemRng ## System thread global RNG

  proc verifyVersionInfo(
    lpVerInfo: ptr OSVERSIONINFOEXW, dwTypeMask: DWORD, dwlConditionMask: uint64
  ): WINBOOL {.importc: "VerifyVersionInfoW", stdcall, dynlib: "kernel32.dll".}

  proc verSetConditionMask(
    conditionMask: uint64, dwTypeMask: DWORD, condition: byte
  ): uint64 {.importc: "VerSetConditionMask", stdcall, dynlib: "kernel32.dll".}

  proc cryptAcquireContext(
    phProv: ptr HCRYPTPROV,
    pszContainer: WideCString,
    pszProvider: WideCString,
    dwProvType: DWORD,
    dwFlags: DWORD,
  ): WINBOOL {.importc: "CryptAcquireContextW", stdcall, dynlib: "advapi32.dll".}

  proc cryptReleaseContext(
    phProv: HCRYPTPROV, dwFlags: DWORD
  ): WINBOOL {.importc: "CryptReleaseContext", stdcall, dynlib: "advapi32.dll".}

  proc cryptGenRandom(
    phProv: HCRYPTPROV, dwLen: DWORD, pBuffer: pointer
  ): WINBOOL {.importc: "CryptGenRandom", stdcall, dynlib: "advapi32.dll".}

  proc rtlGenRandom(
    bufptr: pointer, buflen: ULONG
  ): WINBOOL {.importc: "SystemFunction036", stdcall, dynlib: "advapi32.dll".}

  proc isEqualOrHigher(major: int, minor: int, servicePack: int): bool =
    var mask = 0'u64
    var ov = OSVERSIONINFOEXW(
      dwOSVersionInfoSize: DWORD(sizeof(OSVERSIONINFOEXW)),
      dwMajorVersion: DWORD(major),
      dwMinorVersion: DWORD(minor),
      wServicePackMajor: uint16(servicePack),
      wServicePackMinor: 0,
    )
    let typeMask = DWORD(
      VER_MAJORVERSION or VER_MINORVERSION or VER_SERVICEPACKMAJOR or
        VER_SERVICEPACKMINOR
    )
    mask = verSetConditionMask(mask, VER_MAJORVERSION, VER_GREATER_EQUAL)
    mask = verSetConditionMask(mask, VER_MINORVERSION, VER_GREATER_EQUAL)
    mask = verSetConditionMask(mask, VER_SERVICEPACKMAJOR, VER_GREATER_EQUAL)
    mask = verSetConditionMask(mask, VER_SERVICEPACKMINOR, VER_GREATER_EQUAL)
    verifyVersionInfo(addr ov, typeMask, mask) == 1

  proc newSystemRng(): SystemRng =
    var rng = SystemRng()
    if isEqualOrHigher(6, 0, 0):
      if isEqualOrHigher(6, 0, 1):
        let lib = loadLib("bcrypt.dll")
        if lib != nil:
          var lProc = cast[BCGRMPROC](symAddr(lib, "BCryptGenRandom"))
          if not isNil(lProc):
            rng.bCryptGenRandom = lProc
    var hp: HCRYPTPROV = 0
    let intelDef = newWideCString(INTEL_DEF_PROV)
    let res = cryptAcquireContext(
      addr hp, nil, intelDef, PROV_INTEL_SEC, CRYPT_VERIFYCONTEXT or CRYPT_SILENT
    ).bool
    if res:
      rng.hIntel = hp
    rng

  proc getSystemRng(): SystemRng =
    if isNil(gSystemRng):
      gSystemRng = newSystemRng()
    gSystemRng

  proc randomBytes*(pbytes: pointer, nbytes: int): int =
    let srng = getSystemRng()

    if not isNil(srng.bCryptGenRandom):
      if srng.bCryptGenRandom(
        nil, pbytes, ULONG(nbytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG
      ) == 0:
        return nbytes
    if srng.hIntel != 0:
      if cryptGenRandom(srng.hIntel, DWORD(nbytes), pbytes) != 0:
        return nbytes
    if rtlGenRandom(pbytes, ULONG(nbytes)) != 0:
      return nbytes
    -1

  proc randomClose*() =
    let srng = getSystemRng()
    if srng.hIntel != 0:
      discard cryptReleaseContext(srng.hIntel, 0)

else:
  proc randomBytes*(pbytes: pointer, nbytes: int): int =
    urandomRead(pbytes, nbytes)

proc randomBytes*[T](bytes: var openArray[T]): int =
  let length = len(bytes) * sizeof(T)
  if length == 0:
    return 0
  let res = randomBytes(addr bytes[0], length)
  if res != -1:
    res div sizeof(T)
  else:
    res
