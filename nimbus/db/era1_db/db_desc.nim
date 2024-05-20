# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[os, tables],
  stew/[interval_set, keyed_queue, sorted_set],
  results,
  ../../fluffy/eth_data/era1

const
  NumOpenEra1DbBlocks* = 10

type
  Era1DbError* = enum
    NothingWrong = 0

  Era1DbBlocks* = object
    ## Capability of an `era1` file, to be indexed by starting block num
    fileName*: string                         # File name on disk
    nBlocks*: uint                            # Number of blocks available

  Era1DbRef* = ref object
    dir*: string                              # Database folder
    blocks*: KeyedQueue[uint64,Era1File]      # Era1 block on disk
    byBlkNum*: SortedSet[uint64,Era1DbBlocks] # File access info
    ranges*: IntervalSetRef[uint64,uint64]    # Covered ranges

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc load(db: Era1DbRef, eFile: string) =
  let
    path = db.dir / eFile
    dsc = Era1File.open(path).valueOr:
      return
    key = dsc.blockIdx.startNumber

  if db.blocks.lruFetch(key).isOk or dsc.blockIdx.offsets.len == 0:
    dsc.close()
  else:
    # Add to LRU table
    while NumOpenEra1DbBlocks <= db.blocks.len:
      db.blocks.shift.value.data.close() # unqueue first/least item
    discard db.blocks.lruAppend(key, dsc, NumOpenEra1DbBlocks)

    # Add to index list
    let w = db.byBlkNum.findOrInsert(key).valueOr:
      raiseAssert "Load error, index corrupted: " & $error
    if w.data.nBlocks != 0:
      discard db.ranges.reduce(key, key+w.data.nBlocks.uint64-1)
    w.data.fileName = eFile
    w.data.nBlocks = dsc.blockIdx.offsets.len.uint
    discard db.ranges.merge(key, key+dsc.blockIdx.offsets.len.uint64-1)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
  T: type Era1DbRef;
  dir: string;
    ): T =
  ## Load `era1` index
  result = T(
    dir:      dir,
    byBlkNum: SortedSet[uint64,Era1DbBlocks].init(),
    ranges:   IntervalSetRef[uint64,uint64].init())

  try:
    for w in dir.walkDir(relative=true):
      if w.kind in {pcFile, pcLinkToFile}:
        result.load w.path
  except CatchableError:
    discard

proc dispose*(db: Era1DbRef) =
  for w in db.blocks.nextValues:
    w.close()
  db.blocks.clear()
  db.ranges.clear()
  db.byBlkNum.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
