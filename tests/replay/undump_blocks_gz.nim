# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
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
  ../../execution_chain/db/core_db,
  "."/[gunzip, undump_helpers]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template say(args: varargs[untyped]) =
  # echo args
  discard

# ------------------------------------------------------------------------------
# Public capture
# ------------------------------------------------------------------------------

proc dumpBlocksBegin*(headers: openArray[Header]): string =
  & "transaction #{headers[0].number} {headers.len}"

proc dumpBlocksList*(header: Header; body: BlockBody): string =
  & "block {rlp.encode(header).toHex} {rlp.encode(body).toHex}"

proc dumpBlocksEnd*: string =
  "commit"


proc dumpBlocksEndNl*: string =
  dumpBlocksEnd() & "\n\n"

proc dumpBlocksListNl*(header: Header; body: BlockBody): string =
  dumpBlocksList(header, body) & "\n"

proc dumpBlocksBeginNl*(db: CoreDbTxRef;
                       headers: openArray[Header]): string =
  if headers[0].number == 1'u64:
    let
      h0 = db.getBlockHeader(0'u64).expect("header exists")
      b0 = db.getBlockBody(h0.blockHash).expect("block body exists")
    result = "" &
      dumpBlocksBegin(@[h0]) & "\n" &
      dumpBlocksListNl(h0,b0) &
      dumpBlocksEndNl()

  result &= dumpBlocksBegin(headers) & "\n"


proc dumpBlocksNl*(db: CoreDbTxRef; headers: openArray[Header];
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

iterator undumpBlocksGz*(gzFile: string): seq[EthBlock] =
  var
    blockQ: seq[EthBlock]
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
          blockQ.reset
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
          blockQ.add EthBlock.init(
            rlpHeader.read(Header), rlpBody.read(BlockBody))
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
        yield blockQ
        waitFor = "transaction"
        continue

    echo &"*** Ignoring line({lno}): {line}."
    waitFor = "transaction"

iterator undumpBlocksGz*(gzs: seq[string]): seq[EthBlock] =
  ## Variant of `undumpBlocks()`
  for f in gzs:
    for w in f.undumpBlocksGz:
      yield w

iterator undumpBlocksGz*(
        gzFile: string;                          # Data dump file
        least: uint64;                           # First block to extract
        stopAfter = high(uint64);                # Last block to extract
          ): seq[EthBlock] =
  ## Variant of `undumpBlocks()`
  for seqBlock in gzFile.undumpBlocksGz:
    let b = startAt(seqBlock, least)
    if b.len == 0:
      continue
    let w = stopAfter(b, stopAfter)
    if w.len == 0:
      break
    yield w

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
