# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sequtils, strutils],
  eth/common,
  ../../nimbus/db/era1_db,
  ./undump_helpers

var
  noisy* = false

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpBlocksEra1*(dir: string): (seq[BlockHeader],seq[BlockBody]) =
  let db = Era1DbRef.init dir
  defer: db.dispose()

  doAssert db.hasAllKeys(0,500) # check whether `init()` succeeded

  if noisy: echo "*** undumpBlocksEra1",
     " ranges={", db.blockRanges.toSeq.mapIt(
       "[" & $it.startBlock & "," & $it.endBlock & "]"
     ).join(", ") & "}"

  for w in db.headerBodyPairs:
    yield w


iterator undumpBlocksEra1*(
    dir: string;
    least = low(uint64);                     # First block to extract
    stopAfter = high(uint64);                # Last block to extract
      ): (seq[BlockHeader],seq[BlockBody]) =
  let db = Era1DbRef.init dir
  defer: db.dispose()

  doAssert db.hasAllKeys(0,500) # check whether `init()` succeeded

  if noisy:
    let top = (if stopAfter == high(uint64): ".." else: "," & $stopAfter)
    echo "*** undumpBlocksEra1(", least, top, ")",
     " ranges={", db.blockRanges.toSeq.mapIt(
       "[" & $it.startBlock & "," & $it.endBlock & "]"
     ).join(", ") & "}"

  for (seqHdr,seqBdy) in db.headerBodyPairs:
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
