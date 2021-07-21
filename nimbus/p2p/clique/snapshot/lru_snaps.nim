# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## Snapshot Cache for Clique PoA Consensus Protocol
## ================================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##
## Caveat: Not supporting RLP serialisation encode()/decode()
##

import
  ../../../utils/lru_cache,
  ../clique_cfg,
  ../clique_defs,
  ./snapshot_desc,
  chronicles,
  eth/[common, keys],
  stew/results,
  stint

type
  # Internal type, simplify Hash256 for rlp serialisation
  SnapsKey =
    array[32, byte]

  LruSnapsResult* =
    Result[Snapshot,void]

  LruSnaps* =
    LruCache[Hash256,SnapsKey,LruSnapsResult,CliqueError]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initLruSnaps*(rs: var LruSnaps) {.gcsafe,raises: [Defect].} =

  var toKey: LruKey[Hash256,SnapsKey] =
    proc(h: Hash256): SnapsKey =
      h.data

  var toValue: LruValue[Hash256,LruSnapsResult,CliqueError] =
    proc(h: Hash256): Result[LruSnapsResult,CliqueError] =
      ## blind value, use `setLruSnaps()` to update
      ok(err(LruSnapsResult))

  rs.initCache(toKey, toValue, INMEMORY_SNAPSHOTS)

proc initLruSnaps*(cfg: CliqueCfg): LruSnaps {.gcsafe,raises: [Defect].} =
  result.initLruSnaps


proc hasLruSnaps*(rs: var LruSnaps; hash: Hash256): bool {.inline.} =
  ## Check whether a particular snapshot exists in the cache
  rs.hasKey(hash)

proc setLruSnaps*(rs: var LruSnaps; snaps: Snapshot): bool
                         {.gcsafe, inline, raises: [Defect,CatchableError].} =
  ## Cache/overwite particular snapshot
  rs.setItem(snaps.blockHash, ok(LruSnapsResult,snaps))

proc getLruSnaps*(rs: var LruSnaps; hash: Hash256): LruSnapsResult
                     {.gcsafe, raises: [Defect,CatchableError].} =
  ## Get snapshot from cache, store/return placeholder if there was no cached
  ## snapshot. Use `setLruSnaps()` for updating that entry.
  rs.getItem(hash).value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
