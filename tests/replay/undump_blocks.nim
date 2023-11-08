# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, sequtils, strformat, strutils],
  eth/[common, rlp],
  nimcrypto/utils,
  ../../nimbus/db/core_db,
  ./gunzip

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template say(args: varargs[untyped]) =
  # echo args
  discard

proc startAt(
    h: openArray[BlockHeader];
    b: openArray[BlockBody];
    start: uint64;
      ): (seq[BlockHeader],seq[BlockBody]) =
  ## Filter out blocks with smaller `blockNumber`
  if start.toBlockNumber <= h[0].blockNumber:
    return (h.toSeq,b.toSeq)
  if start.toBlockNumber <= h[^1].blockNumber:
    # There are at least two headers, find the least acceptable one
    var n = 1
    while h[n].blockNumber < start.toBlockNumber:
      n.inc
    return (h[n ..< h.len], b[n ..< b.len])

proc stopAfter(
    h: openArray[BlockHeader];
    b: openArray[BlockBody];
    last: uint64;
      ): (seq[BlockHeader],seq[BlockBody]) =
  ## Filter out blocks with larger `blockNumber`
  if h[^1].blockNumber <= last.toBlockNumber:
    return (h.toSeq,b.toSeq)
  if h[0].blockNumber <= last.toBlockNumber:
    # There are at least two headers, find the last acceptable one
    var n = 1
    while h[n].blockNumber <= last.toBlockNumber:
      n.inc
    return (h[0 ..< n], b[0 ..< n])

# ------------------------------------------------------------------------------
# Public capture
# ------------------------------------------------------------------------------

proc dumpBlocksBegin*(headers: openArray[BlockHeader]): string =
  & "transaction #{headers[0].blockNumber} {headers.len}"

proc dumpBlocksList*(header: BlockHeader; body: BlockBody): string =
  &"block {rlp.encode(header).toHex} {rlp.encode(body).toHex}"

proc dumpBlocksEnd*: string =
  "commit"


proc dumpBlocksEndNl*: string =
  dumpBlocksEnd() & "\n\n"

proc dumpBlocksListNl*(header: BlockHeader; body: BlockBody): string =
  dumpBlocksList(header, body) & "\n"

proc dumpBlocksBeginNl*(db: CoreDbRef;
                       headers: openArray[BlockHeader]): string =
  if headers[0].blockNumber == 1.u256:
    let
      h0 = db.getBlockHeader(0.u256)
      b0 = db.getBlockBody(h0.blockHash)
    result = "" &
      dumpBlocksBegin(@[h0]) & "\n" &
      dumpBlocksListNl(h0,b0) &
      dumpBlocksEndNl()

  result &= dumpBlocksBegin(headers) & "\n"


proc dumpBlocksNl*(db: CoreDbRef; headers: openArray[BlockHeader];
                   bodies: openArray[BlockBody]): string =
  ## Add this below the line `transaction.commit()` in the function
  ## `p2p/chain/persist_blocks.persistBlocksImpl()`:
  ## ::
  ##   dumpStream.write c.db.dumpGroupNl(headers,bodies)
  ##   dumpStream.flushFile
  ##
  ## where `dumpStream` is some stream (think of `stdout`) of type `File`
  ## that could be initialised with
  ## ::
  ##   var dumpStream: File
  ##   if dumpStream.isNil:
  ##     doAssert dumpStream.open("./dump-stream.out", fmWrite)
  ##
  db.dumpBlocksBeginNl(headers) &
    toSeq(countup(0, headers.len-1))
      .mapIt(dumpBlocksListNl(headers[it], bodies[it]))
      .join &
    dumpBlocksEndNl()

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpBlocks*(gzFile: string): (seq[BlockHeader],seq[BlockBody]) =
  var
    headerQ: seq[BlockHeader]
    bodyQ: seq[BlockBody]
    current = 0u
    start = 0u
    top = 0u
    waitFor = "transaction"

  if not gzFile.fileExists:
    raiseAssert &"No such file: \"{gzFile}\""

  for lno,line in gzFile.gunzipLines:
    if line.len == 0 or line[0] == '#':
      continue
    var flds = line.split
    if 0 < flds.len and (waitFor == "" or waitFor == flds[0]):
      case flds[0]
      of "transaction":
        let flds1Len = flds[1].len
        if flds.len == 3 and
           0 < flds1Len and flds[1][0] == '#' and
           0 < flds[2].len:
          start = flds[1][1 ..< flds1Len].parseUInt
          top = start + flds[2].parseUInt
          current = start
          waitFor = ""
          headerQ.reset
          bodyQ.reset
          continue
        else:
          echo &"*** Ignoring line({lno}): {line}."
          waitFor = "transaction"
      of "block":
        if flds.len == 3 and
           0 < flds[1].len and
           0 < flds[2].len and
           start <= current and current < top:
          var
            rlpHeader = flds[1].rlpFromHex
            rlpBody = flds[2].rlpFromHex
          headerQ.add rlpHeader.read(BlockHeader)
          bodyQ.add rlpBody.read(BlockBody)
          current.inc
          continue
        else:
          echo &"*** Ignoring line({lno}): {line}."
          waitFor = "transaction"
      of "commit":
        if current == top:
          say &"*** commit({lno}) #{start}..{top-1}"
        else:
          echo &"*** commit({lno}) error, current({current}) should be {top}"
        yield (headerQ, bodyQ)
        waitFor = "transaction"
        continue

    echo &"*** Ignoring line({lno}): {line}."
    waitFor = "transaction"

iterator undumpBlocks*(gzs: seq[string]): (seq[BlockHeader],seq[BlockBody])=
  ## Variant of `undumpBlocks()`
  for f in gzs:
    for w in f.undumpBlocks:
      yield w

iterator undumpBlocks*(
        gzFile: string;                          # Data dump file
        least: uint64;                           # First block to extract
        stopAfter = high(uint64);                # Last block to extract
          ): (seq[BlockHeader],seq[BlockBody]) =
  ## Variant of `undumpBlocks()`
  for (seqHdr,seqBdy) in gzFile.undumpBlocks:
    let (h,b) = startAt(seqHdr, seqBdy, least)
    if h.len == 0:
      continue
    let w = stopAfter(h, b, stopAfter)
    if w[0].len == 0:
      break
    yield w

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
