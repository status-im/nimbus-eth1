# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Incremental unzip based on `Stream` input (derived from
## `test/replay/unzip.nim`.)

{.push raises:[].}

import
  std/[os, streams, strutils],
  pkg/[chronicles, results, zlib]

logScope:
  topics = "replay gunzip"

const
  DontQuit = low(int)
    ## To be used with `onCloseException()`

  ReadBufLen = 2048
    ## Size of data chunks to be read from stream.

type
  GUnzipStatus* = tuple
    zError: ZError
    info: string

  GUnzipRef* = ref object
    mz: ZStream                   ## Gzip sub-system
    nextInBuf: array[4096,char]   ## Input buffer for gzip `mz.next_in`
    nextOutBuf: array[2048,char]  ## Output buffer for gzip `mz.next_out`

    inStream: Stream              ## Input stream
    inName: string                ## Registered gzip file name (if any)
    outDoneOK: bool               ## Gzip/inflate stream end indicator

    lnCache: string               ## Input line buffer, used by `nextLine`
    lnError: GUnzipStatus         ## Last error cache for line iterator

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
    const blurb = info & "Gunzip exception"
    when quitCode == DontQuit:
      error blurb, error=($e.name), msg=e.msg
    else:
      fatal blurb & " -- STOP", error=($e.name), msg=e.msg
      quit(quitCode)

proc extractLine(gz: GUnzipRef; start: int): Opt[string] =
  ## Extract the first string from line buffer. Any newline characters at
  ## the line end will be stripped. The argument `start` is the position
  ## where to start searching for the `\n` character.
  ##
  # Find `\n` in the buffer if there is any
  if gz.lnCache.len <= start:
    return err()
  var nlPos = gz.lnCache.find(char('\n'), start)
  if nlPos < 0:
    return err()

  # Assemble return value
  var line = gz.lnCache.toOpenArray(0,nlPos-1).substr()
  line.stripLineEnd

  # Update line cache
  gz.lnCache = if gz.lnCache.len <= nlPos + 1: ""
               else: gz.lnCache.toOpenArray(nlPos+1, gz.lnCache.len-1).substr()

  # Done
  ok(move line)

# ------------------------------------------------------------------------------
# Private inflate function
# ------------------------------------------------------------------------------

proc loadInput(gz: GUnzipRef; data: openArray[char]): string =
  ## Fill input chache for `explode()` and return the overflow.
  ##
  # Gzip input buffer general layout
  # ::
  #    | <---------------- nextInBuf.len -------------------------> |
  #    |--------------------+--------------------+------------------|
  #    | <--- total_in ---> | <--- avail_in ---> | <--- unused ---> |
  #    |                    |
  #    nextInBuf            next_in
  #
  # to be initialised as
  # ::
  #    | <---------------- nextInBuf.len -------------------------> |
  #    |--------------------------+---------------------------------|
  #    | <------ avail_in ------> | <----------- unused ----------> |
  #    |
  #    nextInBuf
  #    next_in
  #
  var buffer = newSeqUninit[char](gz.mz.avail_in.int + data.len)

  # Collect remaining data first
  if 0 < gz.mz.avail_in:
    (addr buffer[0]).copyMem(gz.mz.next_in, gz.mz.avail_in)

  # Append new data
  (addr buffer[gz.mz.avail_in]).copyMem(addr data[0], data.len)

  # Realign gzip input buffer and fill as much as possible from `buffer[]`
  gz.mz.next_in = cast[ptr uint8](addr gz.nextInBuf[0])
  gz.mz.total_in = 0

  if gz.nextInBuf.len < buffer.len:
    # The `buffer[]` does not fully fit into `nextInBuf[]`.
    (addr gz.nextInBuf).copyMem(addr buffer[0], gz.nextInBuf.len)
    gz.mz.avail_in = gz.nextInBuf.len.cuint
    # Return overflow
    return buffer.toOpenArray(gz.nextInBuf.len, buffer.len-1).substr()

  (addr gz.nextInBuf).copyMem(addr buffer[0], buffer.len)
  gz.mz.avail_in = buffer.len.cuint
  return ""


proc explodeImpl(gz: GUnzipRef; overflow: var string): Result[string,ZError] =
  ## Implement `explode()` processing.
  ##
  if gz.outDoneOK:
    return err(Z_STREAM_END)

  var
    outData = ""
    zRes = Z_STREAM_END

  while not gz.outDoneOK and 0 < gz.mz.avail_in:
    gz.mz.next_out = cast[ptr uint8](addr gz.nextOutBuf[0])
    gz.mz.avail_out = gz.nextOutBuf.len.cuint
    gz.mz.total_out = 0

    # Save input state to compare with, below
    let availIn = gz.mz.avail_in

    # Deflate current block `next_in[]` => `next_out[]`
    zRes = gz.mz.inflate(Z_SYNC_FLUSH)
    if zRes == Z_STREAM_END:
      gz.outDoneOK = true
      zRes = gz.mz.inflateEnd()
      # Dont't stop here, `outData` needs to be assigned
    if zRes != Z_OK:
      break

    # Append processed data
    if 0 < gz.mz.total_out:
      outData &= gz.nextOutBuf.toOpenArray(0, gz.mz.total_out-1).substr()

    if gz.outDoneOK:
      break

    if gz.mz.avail_in < availIn:
      # Re-load overflow
      if 0 < overflow.len:
        overflow = gz.loadInput overflow.toOpenArray(0, overflow.len-1)

    elif gz.mz.avail_out == gz.nextOutBuf.len.cuint:
      # Stop unless state change
      zRes = Z_BUF_ERROR
      break

  if zRes != Z_OK:
    return err(zRes)

  ok(outData)


proc explode(gz: GUnzipRef; data: openArray[char]): Result[string,ZError] =
  ## Inflate the `data[]` argument together with the rest from the previous
  ## inflation action and returns the inflated value (and possibly the input
  ## buffer overflow.)
  ##
  var overflow = gz.loadInput data
  gz.explodeImpl(overflow)

proc explode(gz: GUnzipRef): Result[string,ZError] =
  ## Variant of `explode()` which clears the rest of the input buffer.
  ##
  var overflow = ""
  gz.explodeImpl(overflow)

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc init*(T: type GUnzipRef; inStream: Stream): Result[T,GUnzipStatus] =
  ## Set up gUnzip filter and prepare for deflating.
  ##
  const info = "GUnzipRef.init(): "
  var chunk: array[ReadBufLen,char]

  # Read header buffer from stream
  var chunkLen: int
  info.onException(DontQuit):
    chunkLen = inStream.readData(addr chunk, chunk.len)

  # Parse GZIP header (RFC 1952)
  if chunkLen < 18:
    return err((Z_STREAM_ERROR, "Stream too short"))
  if (chunk[0].ord != 0x1f or            # magic number
      chunk[1].ord != 0x8b or            # magic number
      chunk[2].ord != 0x08) or           # deflate
     (chunk[3].ord and 0xf7) != 0:       # unsupported flags
    return err((Z_STREAM_ERROR, "Wrong magic or flags"))

  # Set start of payload
  var
    pylStart = 10
    inName = ""
  if (chunk[3].ord and 8) == 8:          # FNAME
    var endPos = chunk.toOpenArray(pylStart, chunkLen-1).find char(0)
    if endPos < 0:
      return err((Z_STREAM_ERROR, "Advertised but missing file name"))
    endPos += pylStart # need absolute position in `chunk[]`
    inName = chunk.toOpenArray(pylStart, endPos-1).substr()
    pylStart = endPos + 1

  # Initialise descriptor
  let gz = GUnzipRef(
    inStream: inStream,
    inName:   inName)

  # Initialise `zlib` and return
  let gRc = gz.mz.inflateInit2(Z_RAW_DEFLATE)
  if gRc != Z_OK:
    return err((gRc,"Zlib init error"))

  # Store unused buffer data for the first read
  gz.mz.avail_in = (chunk.len - pylStart).cuint
  (addr gz.nextInBuf).copyMem(addr chunk[pylStart], gz.mz.avail_in.int)
  gz.mz.next_in = cast[ptr uint8](addr gz.nextInBuf[0])
  gz.mz.total_in = 0                     # i.e. left aligned data

  ok(gz)

proc name*(gz: GUnzipRef): string =
  ## Getter: returns registered name (if any)
  gz.inName


proc nextChunk*(gz: GUnzipRef): Result[string,GUnzipStatus] =
  ## Fetch next unzipped data chunk, return and empty string if input
  ## is exhausted.
  ##
  const info = "nextChunk(GUnzipRef): "

  if gz.outDoneOK:
    return err((Z_STREAM_END,""))

  var
    chunk: array[ReadBufLen,char]
    chunkLen = 0
    data = ""

  info.onException(DontQuit):
    chunkLen = gz.inStream.readData(addr chunk, chunk.len)

  if 0 < chunkLen:
    data = gz.explode(chunk.toOpenArray(0, chunkLen-1)).valueOr:
      return err((error,"Decoding error"))
  else:
    var atEnd = false
    info.onException(DontQuit):
      atEnd = gz.inStream.atEnd()
    if atEnd:
      data = gz.explode().valueOr:
        return err((error,"Decoding error"))
    else:
      return err((Z_STREAM_ERROR, "Stream too short"))

  return ok(move data)


proc nextLine*(gz: GUnzipRef): Result[string,GUnzipStatus] =
  ## If the gzip stream is expected to contain text data only it can be
  ## retrieved line wise. The line string returned has the EOL characters
  ## stripped.
  ##
  ## If all lines are exhausted, the error code `Z_STREAM_END` is returned.
  ##
  # Check whether there is a full line in the buffer, already
  gz.extractLine(0).isErrOr:
    return ok(value)

  # Load next chunk(s) into line cache and (try to) extract a complete line.
  while not gz.outDoneOK:
    let chunk = gz.nextChunk().valueOr:
      if gz.outDoneOK:
        break
      return err(error)

    # Append data chunk to line cache and (try to) extract a line.
    let inLen = gz.lnCache.len
    gz.lnCache &= chunk
    gz.extractLine(inLen).isErrOr:
      return ok(value)
    # continue

  # Last line (may be partial)
  if 0 < gz.lnCache.len:
    var line = gz.lnCache
    line.stripLineEnd
    gz.lnCache = ""
    return ok(move line)

  err((Z_STREAM_END,""))


proc atEnd*(gz: GUnzipRef): bool =
  ## Returns `true` if data are exhausted.
  gz.outDoneOK and gz.lnCache.len == 0


iterator line*(gz: GUnzipRef): string =
  ## Iterate over `nextLine()` until the input stream is exhausted.
  gz.lnError = (Z_OK, "")
  while true:
    var ln = gz.nextLine().valueOr:
      gz.lnError = error
      break
    yield ln

func lineStatus*(gz: GUnzipRef): GUnzipStatus =
  ## Error (or no-error) status after the `line()` iterator has terminated.
  gz.lnError

func lineStatusOk*(gz: GUnzipRef): bool =
  ## Returns `true` if the `line()` iterator has terminated without error.
  gz.lnError[0] in {Z_OK, Z_STREAM_END}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
