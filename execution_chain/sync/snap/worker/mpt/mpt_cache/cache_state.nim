# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## State data records
## -------------------
##
## * State context data:
##   + key33: <col, root>
##   + value: <hash, number, touch, tag, coverage>
##   where
##   + col:      `cStateData`
##   + root:     `StateRoot`
##   + hash:     `BlockHash`
##   + number:   `BlockNumber`
##   + touch:    `Moment`
##   + tag:      `StateDataTag`
##   * coverage: `UInt256`
##

{.push raises: [].}

import
  pkg/[chronos, eth/common, results],
  ../../state_db,
  ./[cache_api1, cache_api33, cache_desc,
     cache_const, cache_iter, cache_rlp]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc hasStateData*(
    db: MptAsmRef;
      ): Result[bool,string] =
  for (_,value) in db.adb.colWalk33 cStateData.key33():
    value.decodeStateData().isOkOr:
      return err(error)
    return ok(true)
  ok(false)

proc getStateData*(
    db: MptAsmRef;
    root: StateRoot;
      ): Result[CacheStateData,string] =
  let data = db.get33(cStateData, root).valueOr:
    return err(error)
  data.decodeStateData()

proc putStateData*(
    db: MptAsmRef;
    root: StateRoot;
    data: CacheStateData;
      ): PutResult =
  db.put33(cStateData, root, encodeStateData(
    data.hash, data.number, data.touch, data.tag, data.coverage))

proc putStateData*(
    db: MptAsmRef;
    root: StateRoot;
    hash: BlockHash;
    number: BlockNumber;
    touch: Moment;
    tag: StateDataTag;
    coverage: UInt256;
      ): PutResult =
  db.put33(cStateData, root,
           encodeStateData(hash, number, touch, tag, coverage))

proc delStateData*(db: MptAsmRef; root: StateRoot): DelResult =
  db.del33(cStateData, root)

proc clearStateData*(db: MptAsmRef): DelResult =
  db.clr1 cStateData

iterator walkStateData*(db: MptAsmRef): WalkStateData =
  for (key,value) in db.adb.colWalk33 cStateData.key33():
    let w = value.decodeStateData().valueOr:
        var oops: WalkStateData
        oops.root = StateRoot(key)
        oops.error = error
        yield oops
        continue
    yield (StateRoot(key), w, "")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
