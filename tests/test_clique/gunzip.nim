# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strutils,
  stew/results,
  zlib

type
  GUnzip = object
    mz: ZStream

    # fields used in explode()
    inCache: string
    inCount: uint
    outBuf: array[4096,char]
    outCount: uint
    outDoneOK: bool

    # fields used by nextChunk()
    gzIn: File
    gzOpenOK: bool
    gzMax: int64
    gzCount: int64
    gzName: string

    # fields used by nextLine()
    lnList: seq[string]
    lnInx: int

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private deflate helpers:
# ------------------------------------------------------------------------------

proc explode(state: var GUnzip; data: openArray[char];
             start, dataLen: int): Result[string,ZError] =
  var
    inBuf = state.inCache & data[start ..< start + dataLen].join
    outData = ""
    rc: ZError

  state.mz.next_in  = cast[ptr cuchar](inBuf[0].addr)
  state.mz.total_in = 0
  state.mz.avail_in = inBuf.len.cuint

  while not state.outDoneOK and 0 < state.mz.avail_in:
    state.mz.next_out = cast[ptr cuchar](state.outBuf[0].addr)
    state.mz.avail_out = state.outBuf.len.cuint
    state.mz.total_out = 0

    # Save inpust state to compare with later on
    let availIn = state.mz.avail_in

    # Deflate current block next_in[] => next_out[]
    rc = state.mz.inflate(Z_SYNC_FLUSH)
    if rc == Z_STREAM_END:
      state.outDoneOK = true
      rc = state.mz.inflateEnd
    if rc != Z_OK:
      break

    # Append processed data
    if 0 < state.mz.total_out:
      outData &= toOpenArray(state.outBuf, 0, state.mz.total_out-1).join
      state.outCount += state.mz.total_out.uint

    # Stop unless state change
    if state.mz.avail_in == availIn and
       state.mz.avail_out == state.outBuf.len.cuint:
      break

  # Cache left-over for next gzExplode() session
  state.inCount +=  state.mz.total_in.uint
  state.inCache =
    if state.mz.total_in.int < inBuf.len - 1:
      inBuf[state.mz.total_in.int ..< inBuf.len]
    else:
      ""

  # Return code
  if rc != Z_OK:
    err(rc)
  else:
    ok(outData)

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc open*(state: var GUnzip; fileName: string):
                      Result[void,ZError] {.gcsafe, raises: [Defect,IOError].} =
  ## Open gzipped file with path `fileName` and prepare for deflating and
  ## extraction.

  # Clear descriptor
  if state.gzOpenOK:
    state.gzIn.close
  state.reset

  var
    strBuf = 1024.newString
    start = 10
    rc = state.mz.inflateInit2(Z_RAW_DEFLATE)
  doAssert rc == Z_OK

  state.gzIn = fileName.open(fmRead)
  state.gzOpenOK = true
  state.gzMax = state.gzIn.getFileSize
  state.gzCount = state.gzIn.readChars(strBuf, 0, strBuf.len)

  # Parse GZIP header (RFC 1952)
  doAssert 18 < state.gzCount
  doAssert (strBuf[0].ord == 0x1f and     # magic number
            strBuf[1].ord == 0x8b and     # magic number
            strBuf[2].ord == 0x08)        # deflate
  doAssert (strBuf[3].ord and 0xf7) == 0  # unsupported flags
  if (strBuf[3].ord and 8) == 8:          # FNAME
    let endPos = strBuf.find(0.chr, start)
    state.gzName = strBuf[start ..< endPos]
    start = endPos + 1

  # Cut off trailor
  state.gzMax -= 8
  if state.gzMax < state.gzCount:
    state.gzCount = state.gzMax

  # Store unused data for the next read
  state.inCache = strBuf[start ..< state.gzCount]
  return ok()


proc close*(state: var GUnzip) {.gcsafe.} =
  ## Close any open files and free resources
  if state.gzOpenOK:
    state.gzIn.close
    state.reset


proc nextChunk*(state: var GUnzip):
                Result[string,ZError] {.gcsafe, raises: [Defect,IOError].} =
  ## Fetch next unzipped data chunk, return and empty string if input
  ## is exhausted.
  var strBuf = 4096.newString
  result = ok("")

  while state.gzCount < state.gzMax:
    var strLen = state.gzIn.readChars(strBuf, 0, strBuf.len)
    if state.gzMax < state.gzCount + strLen:
      strLen = (state.gzMax - state.gzCount).int
    state.gzCount += strLen

    result = state.explode(strBuf, 0, strLen)
    if result.isErr:
      state.close
      return
    if result.value != "":
      return


proc nextChunkOk*(state: var GUnzip): bool {.inline,gcsafe.} =
  ## True if there is another chunk of data so that `nextChunk()` might
  ## fetch another non-empty unzipped data chunk.
  state.gzCount < state.gzMax


proc nextLine*(state: var GUnzip):
             Result[string,ZError] {.gcsafe, raises: [Defect,IOError].} =
  ## Assume that the `state` argument descriptor referes to a gzipped text
  ## file with lines separated by a newline character. Then fetch the next
  ## unzipped line and return it.
  ##
  ## If all lines are exhausted, the error `Z_STREAM_END` is returned. See
  ## function `nextLineOk()` for inquiry whether there would be a next
  ## unzipped line, at all.

  # Return next item from list (but spare the last)
  if state.lnInx + 1 < state.lnList.len:
    result = ok(state.lnList[state.lnInx])
    state.lnInx += 1

  elif not state.nextChunkOk:
    result = err(Z_STREAM_END)

  else:
    # Need to refill, concatenate old last item with new first
    if state.lnInx + 1 == state.lnList.len:
      state.lnList = @[state.lnList[state.lnInx]]

    # First encounter => initialise
    else:
      state.lnList = @[""]

    # Fetch at least two lines
    while state.nextChunkOk and state.lnList.len < 2:
      let rc = state.nextChunk
      if rc.isErr:
        return rc
      var q = rc.value.split('\n')
      q[0] = state.lnList[0] & q[0]
      state.lnList = q

    result = ok(state.lnList[0])
    state.lnInx = 1


proc nextLineOk*(state: var GUnzip): bool {.inline,gcsafe.} =
  ## True if there is another unzipped line available with `nextLine()`.
  state.nextChunkOk or state.lnInx + 1 < state.lnList.len


iterator gunzipLines*(state: var GUnzip):
                            (int,string) {.gcsafe, raises: [Defect,IOError].} =
  ## Iterate over all lines of gzipped text file `fileName` and return
  ## the pair `(line-number,line-text)`
  var lno = 0
  while state.nextLineOk:
    let rc = state.nextLine
    if rc.isErr:
      break
    lno.inc
    yield (lno,rc.value)


iterator gunzipLines*(fileName: string):
                            (int,string) {.gcsafe, raises: [Defect,IOError].} =
  ## Open a gzipped text file, iterate over its lines (using the other
  ## version of `gunzipLines()`) and close it.
  var state: GUnzip
  doAssert state.open(fileName).isOk
  defer: state.close

  for w in state.gunzipLines:
    yield w

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
