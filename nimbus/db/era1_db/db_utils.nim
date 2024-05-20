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
  std/os,
  eth/common,
  stew/[interval_set, keyed_queue, sorted_set],
  ../../fluffy/eth_data/era1,
  ./db_desc

export
  BlockTuple

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getEra1DbBlocks(
    db: Era1DbRef;
    bn: uint64;
      ): Result[SortedSetItemRef[uint64,Era1DbBlocks],void] =
  ## Get item referring to particular `era1` file
  let w = db.byBlkNum.le(bn).valueOr:
    return err()
  if w.key + w.data.nBlocks <= bn:
    return err()
  ok(w)

proc deleteEra1DbBlocks(
   db: Era1DbRef;
   it: SortedSetItemRef[uint64,Era1DbBlocks];
      ) =
  ## Remove `era1` file index descriptor from list and LRU table
  discard db.byBlkNum.delete it.key
  db.blocks.del it.key
  discard db.ranges.reduce(it.key, it.data.nBlocks-1)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hasAllKeys*(db: Era1DbRef, first, last: uint64): bool =
  if first <= last:
    db.ranges.covered(first, last) == last - first + 1
  else:
    false

proc hasSomeKey*(db: Era1DbRef, first, last: uint64): bool =
  if first <= last:
    0 < db.ranges.covered(first, last)
  else:
    false

proc hasKey*(db: Era1DbRef, key: uint64): bool =
  0 < db.ranges.covered(key, key)


proc fetch*(
    db: Era1DbRef;
    blockNumber: uint64;
    updateInxOnError = true;
      ): Result[BlockTuple,string] =
  ## Fetch block data for argument height `blockNumber`. If `updateInxOnError`
  ## is set `true` (which is the default), a data file that cannot be opened
  ## anymore will be ignored in future.
  ##
  let blkDsc = db.getEra1DbBlocks(blockNumber).valueOr:
    return err("")

  # Get `era1` file index descriptor
  let dsc = block:
    let rc = db.blocks.lruFetch(blkDsc.key)
    if rc.isOk:
      rc.value
    else:
      let w = Era1File.open(db.dir / blkDsc.data.fileName).valueOr:
        if updateInxOnError:
          db.deleteEra1DbBlocks blkDsc
        return err("") # no way
      while NumOpenEra1DbBlocks <= db.blocks.len:
        db.blocks.shift.value.data.close() # unqueue first/least item
      discard db.blocks.lruAppend(blkDsc.key, w, NumOpenEra1DbBlocks)
      w

  # Fetch the result via `dsc`
  dsc.getBlockTuple(blockNumber)


proc clearInx*(db: Era1DbRef, blockNumber: uint64): bool {.discardable.} =
  ## Remove the `era1` block containing `blockNumber` from index. This might
  ## be useful after rejection the block contents for height `blockNumber`.
  ##
  ## The function returns true if the index was found and could be cleared.
  ##
  let blkDsc = db.getEra1DbBlocks(blockNumber).valueOr:
    return false

  db.deleteEra1DbBlocks blkDsc
  true

# -----------------

iterator blockRanges*(db: Era1DbRef): tuple[startBlock,endBlock: uint64] =
  for w in db.ranges.increasing:
    yield (w.minPt, w.maxPt)


iterator headerBodyPairs*(
    db: Era1DbRef;
    firstBlockNumber = 0u64;
    maxBlockNumber = high(uint64);
    blocksPerUnit = 192;
      ): (seq[BlockHeader],seq[BlockBody]) =
  ## Provide blocks until there are no more or the block number exceeds
  ## `maxBlockNumber`.
  ##
  let uSize = blocksPerUnit.uint64
  var left = 1u64

  block yieldBody:
    if 0 < firstBlockNumber:
      left = firstBlockNumber
    elif db.hasKey(0):
      # Zero block (aka genesis)
      let tp = db.fetch(0).expect "valid genesis"
      yield(@[tp.header],@[tp.body])
    else:
      break yieldBody # no way

    # Full block ranges
    while left+uSize < maxBlockNumber and db.hasAllKeys(left,left+uSize-1):
      var
        hdr: seq[BlockHeader]
        bdy: seq[BlockBody]
      for bn in left ..< left+uSize:
        let tp = db.fetch(bn).expect "valid block tuple"
        hdr.add tp.header
        bdy.add tp.body
      yield(hdr,bdy)
      left += uSize

    # Final range (if any)
    block:
      var
        hdr: seq[BlockHeader]
        bdy: seq[BlockBody]
      while left <= maxBlockNumber and db.hasKey(left):
        let tp = db.fetch(left).expect "valid block tuple"
        hdr.add tp.header
        bdy.add tp.body
        left.inc
      if 0 < hdr.len:
        yield(hdr,bdy)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
