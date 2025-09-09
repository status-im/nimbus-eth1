# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay environment

{.push raises:[].}

import
  std/[endians, os, streams, strutils],
  pkg/[chronicles, eth/common, zlib],
  ../replay_desc

logScope:
  topics = "replay reader"

type
  FileSignature = enum
    Unknown = 0
    Plain
    Gzip

const
  DontQuit = low(int)
    ## To be used with `onCloseException()`

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template onException(
    info: static[string];
    quitCode: static[int];
    code: untyped) =
  try:
    code
  except CatchableError as e:
    const blurb = info & "Replay stream exception"
    when quitCode == DontQuit:
      error blurb, error=($e.name), msg=e.msg
    else:
      fatal blurb & " -- STOP", error=($e.name), msg=e.msg
      quit(quitCode)

proc getFileSignature(strm: Stream): (FileSignature,uint16) =
  const info = "getSignature(): "
  var u16: uint16
  info.onException(QuitFailure):
    let v16 = strm.peekUint16()
    (addr u16).bigEndian16(addr v16)

  # Gzip signature
  if u16 == 0x1f8b'u16:
    return (Gzip,u16)

  # Ascii signature: /[0-9A-Z] /
  let (c0, c1) = (char(u16 shr 8), char(u16.uint8))
  if (c0.isDigit or c0.isUpperAscii or c0 == '#') and (c1 in {' ','\r','\n'}):
    return (Plain,u16)

  (Unknown,u16)

# ------------------------------------------------------------------------------
# Private record reader functions
# ------------------------------------------------------------------------------

proc plainReadLine(rp: ReplayReaderRef): Opt[string] =
  const info = "plainReadLine(): "
  info.onException(DontQuit):
    if not rp.inStream.atEnd():
      return ok(rp.inStream.readLine)
  err()

proc plainAtEnd(rp: ReplayReaderRef): bool =
  const info = "plainAtEnd(): "
  info.onException(DontQuit):
    return rp.inStream.atEnd()
  true

proc gUnzipReadLine(rp: ReplayReaderRef): Opt[string] =
  const info = "gUnzipReadLine(): "
  var rc = Result[string,GUnzipStatus].err((Z_STREAM_ERROR,""))
  info.onException(DontQuit):
    rc = rp.gzFilter.nextLine()
  if rc.isErr():
    if not rp.gzFilter.lineStatusOk():
      let err = rp.gzFilter.lineStatus()
      info info & "GUnzip filter error", zError=err.zError, info=err.info
    return err()
  ok(rc.value)

proc gUnzipAtEnd(rp: ReplayReaderRef): bool =
  rp.gzFilter.atEnd()

# ------------------------------------------------------------------------------
# Public constructor(s)
# ------------------------------------------------------------------------------

proc init*(T: type ReplayReaderRef; strm: Stream): T =
  const info = "ReplayReaderRef.init(): "

  if strm.isNil:
    fatal info & "Cannot use nil stream for reading -- STOP"
    quit(QuitFailure)

  let
    (sig, u16) = strm.getFileSignature()          # Check file encoding
    rp = T(inStream: strm)                        # Set up descriptor

  # Set up line reader, probably with gunzip/deflate filter
  case sig:
  of Plain:
    rp.readLine = plainReadLine
    rp.atEnd = plainAtEnd
  of Gzip:
    var rc = Result[GUnzipRef,GUnzipStatus].err((Z_STREAM_ERROR,""))
    info.onException(DontQuit):
      rc = GUnzipRef.init(strm)
    if rc.isErr:
      fatal info & "Cannot assign gunzip reader -- STOP"
      quit(QuitFailure)
    rp.gzFilter = rc.value
    rp.readLine = gUnzipReadLine
    rp.atEnd = gUnzipAtEnd
  of Unknown:
    fatal info & "Unsupported file encoding -- STOP",
      fileSignature=("0x" & $u16.toHex(4))
    quit(QuitFailure)

  rp


proc destroy*(rp: ReplayReaderRef) =
  const info = "destroy(ReplayReaderRef): "
  info.onException(DontQuit):
    rp.inStream.flush()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
