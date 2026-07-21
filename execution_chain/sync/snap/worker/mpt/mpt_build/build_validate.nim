# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ./[build_desc, build_export, build_finalise, build_init, build_merge]

const
  ffffHash = high(ItemKey).to(Hash32)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc validate*[T: SnapAccount|StorageItem](
    root: StateRoot|StoreRoot;
    start: ItemKey;
    leafs: openArray[T];
    proof: openArray[ProofNode];
      ): Opt[NodeTrieRef] =
  ## Validate snap accounts or storage slot data package.
  ##
  when root is StateRoot and T isnot SnapAccount:
    {.error: "Leafs item must be of type SnapAccount for root type StateRoot".}
  elif root is StoreRoot and T isnot StorageItem:
    {.error: "Leafs item must be of type StorageItem for root type StoreRoot".}

  when T is SnapAccount:
    template key(acc: SnapAccount): Hash32 = acc.accHash
  elif T is StorageItem:
    template key(sto: StorageItem): Hash32 = sto.slotHash
  else:
    {.error: "Unexpedted type for leafs[]".}        # `T` type was extended?

  let
    limit = if 0 < leafs.len: leafs[^1].key else: ffffHash
    db = NodeTrieRef.init(root, start, proof, limit)

  if not db.isNil:
    var lastKey = low(ItemKey)                      # leaf keys must increase
    for leaf in leafs:
      let key = leaf.key.to(ItemKey)
      if key <= lastKey:                            # this excludes zero `key`
        return err()                                # keys not increasing
      if db.merge(leaf).isErr:
        return err()
      lastKey = key

    discard db.finalise()
    if db.isComplete():
      return ok(db)
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
