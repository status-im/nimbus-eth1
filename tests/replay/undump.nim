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
  std/[sequtils, strformat, strutils],
  ../../nimbus/db/db_chain,
  ./gunzip,
  eth/[common, rlp],
  nimcrypto,
  stew/results

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template say(args: varargs[untyped]) =
  # echo args
  discard

proc toByteSeq(s: string): seq[byte] =
  nimcrypto.fromHex(s)

# ------------------------------------------------------------------------------
# Public capture
# ------------------------------------------------------------------------------

proc dumpGroupBegin*(headers: openArray[BlockHeader]): string =
  & "transaction #{headers[0].blockNumber} {headers.len}"

proc dumpGroupBlock*(header: BlockHeader; body: BlockBody): string =
  &"block {rlp.encode(header).toHex} {rlp.encode(body).toHex}"

proc dumpGroupEnd*: string =
  "commit"


proc dumpGroupEndNl*: string =
  dumpGroupEnd() & "\n\n"

proc dumpGroupBlockNl*(header: BlockHeader; body: BlockBody): string =
  dumpGroupBlock(header, body) & "\n"

proc dumpGroupBeginNl*(db: BaseChainDB;
                       headers: openArray[BlockHeader]): string =
  if headers[0].blockNumber == 1.u256:
    let
      h0 = db.getBlockHeader(0.u256)
      b0 = db.getBlockBody(h0.blockHash)
    result = "" &
      dumpGroupBegin(@[h0]) & "\n" &
      dumpGroupBlockNl(h0,b0) &
      dumpGroupEndNl()

  result &= dumpGroupBegin(headers) & "\n"


proc dumpGroupNl*(db: BaseChainDB; headers: openArray[BlockHeader];
                  bodies: openArray[BlockBody]): string =
  ## Add this below the line `transaction.commit()` in the function
  ## `p2p/chain.persist_blocks.persistBlocksImpl()`:
  ## ::
  ##   dumpStream.write c.db.dumpGroupNl(headers,bodies)
  ##
  ## where `dumpStream` is some stream (think of `stdout`) of type `File`
  ## that could be initialised with
  ## ::
  ##   var dumpStream: File
  ##   dumpStream.open("./dump-stream.out", fmWrite)
  ##
  db.dumpGroupBeginNl(headers) &
    toSeq(countup(0, headers.len-1))
      .mapIt(dumpGroupBlockNl(headers[it], bodies[it]))
      .join &
    dumpGroupEndNl()

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpNextGroup*(gzFile: string): (seq[BlockHeader],seq[BlockBody]) =
  var
    headerQ: seq[BlockHeader]
    bodyQ: seq[BlockBody]
    line = ""
    lno = 0
    current = 0u
    start = 0u
    top = 0u
    waitFor = "transaction"

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
