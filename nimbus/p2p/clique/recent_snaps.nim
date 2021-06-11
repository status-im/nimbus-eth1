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
  ../../utils,
  ../../utils/lru_cache,
  ./clique_cfg,
  ./clique_defs,
  ./clique_utils,
  ./snapshot,
  chronicles,
  eth/[common, keys],
  nimcrypto,
  sequtils,
  stint

export
  snapshot

type
  RecentArgs* = ref object
    blockHash*: Hash256
    blockNumber*: BlockNumber
    parents*: seq[BlockHeader]

  # Internal, temporary state variables
  LocalArgs = ref object
    headers: seq[BlockHeader]

  # Internal type, simplify Hash256 for rlp serialisation
  RecentKey = array[32, byte]

  # Internal descriptor used by toValue()
  RecentDesc = object
    cfg: CliqueCfg
    args: RecentArgs
    local: LocalArgs

  RecentSnaps* = object
    cfg: CliqueCfg
    cache: LruCache[RecentDesc,RecentKey,Snapshot,CliqueError]

{.push raises: [Defect,CatchableError].}

logScope:
  topics = "clique PoA recent-snaps"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# clique/clique.go(394): if number == 0 || (number%c.config.Epoch [..]
proc canDiskCheckPointOk(d: RecentDesc): bool =
  # If we're at the genesis, snapshot the initial state.
  if d.args.blockNumber.isZero:
    return true
  # Alternatively if we're at a checkpoint block without a parent
  # (light client CHT), or we have piled up more headers than allowed
  # to be re-orged (chain reinit from a freezer), consider the
  # checkpoint trusted and snapshot it.
  if (d.args.blockNumber mod d.cfg.epoch) == 0:
    if FULL_IMMUTABILITY_THRESHOLD < d.local.headers.len:
      return true
    if d.cfg.dbChain.getBlockHeaderResult(d.args.blockNumber - 1).isErr:
      return true

proc isCheckPointOk(number: BlockNumber): bool =
  (number mod CHECKPOINT_INTERVAL) == 0

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# clique/clique.go(383): if number%checkpointInterval == 0 [..]
proc tryDiskSnapshot(d: RecentDesc; snap: var Snapshot): bool =
  if d.args.blockNumber.isCheckPointOk:
    if snap.loadSnapshot(d.cfg, d.args.blockHash).isOk:
      trace "Loaded voting snapshot from disk",
        blockNumber = d.args.blockNumber,
        blockHash = d.args.blockHash
      return true

proc tryDiskCheckPoint(d: RecentDesc; snap: var Snapshot): bool =
  if d.canDiskCheckPointOk:
    # clique/clique.go(395): checkpoint := chain.GetHeaderByNumber [..]
    let checkPoint = d.cfg.dbChain.getBlockHeaderResult(d.args.blockNumber)
    if checkPoint.isErr:
      return false
    let
      hash = checkPoint.value.hash
      signersList = checkPoint.value.extraData.extraDataSigners
    snap.initSnapshot(d.cfg, d.args.blockNumber, hash, signersList)

    if snap.storeSnapshot.isOk:
      info "Stored checkpoint snapshot to disk",
        blockNumber = d.args.blockNumber,
        blockHash = hash
      return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initRecentSnaps*(rs: var RecentSnaps;
                      cfg: CliqueCfg) {.gcsafe,raises: [Defect].} =

  var toKey: LruKey[RecentDesc,RecentKey] =
    proc(d: RecentDesc): RecentKey =
      d.args.blockHash.data

  var toValue: LruValue[RecentDesc,Snapshot,CliqueError] =
    proc(d: RecentDesc): Result[Snapshot,CliqueError] =
      var snap: Snapshot

      while true:
        # If an on-disk checkpoint snapshot can be found, use that
        if d.tryDiskSnapshot(snap):
          # clique/clique.go(386): snap = s
          break

        # Save checkpoint e.g. when at the genesis ..
        if d.tryDiskCheckPoint(snap):
          # clique/clique.go(407): log.Info("Stored [..]
          break

        # No snapshot for this header, gather the header and move backward
        var header: BlockHeader
        if 0 < d.args.parents.len:
          # If we have explicit parents, pick from there (enforced)
          header = d.args.parents[^1]

          # clique/clique.go(416): if header.Hash() != hash [..]
          if header.hash != d.args.blockHash and
             header.blockNumber != d.args.blockNumber:
            return err((errUnknownAncestor,""))
          d.args.parents.setLen(d.args.parents.len-1)

        else:
          # No explicit parents (or no more left), reach out to the database
          let rc = d.cfg.dbChain.getBlockHeaderResult(d.args.blockNumber)
          if rc.isErr:
            return err((errUnknownAncestor,""))
          header = rc.value

        d.local.headers.add header
        d.args.blockNumber -= 1.u256
        d.args.blockHash = header.parentHash
        # => while loop

      # Previous snapshot found, apply any pending headers on top of it
      for i in 0 ..< d.local.headers.len div 2:
        # Reverse lst order
        swap(d.local.headers[i], d.local.headers[^(1+i)])
      block:
        # clique/clique.go(434): snap, err := snap.apply(headers)
        echo ">>> calling applySnapshot(",
                   d.local.headers.mapIt(it.blockNumber.truncate(int)), ")"
        let rc = snap.applySnapshot(d.local.headers)
        echo "<<< calling applySnapshot() => ", rc.pp
        if rc.isErr:
          return err(rc.error)

      # If we've generated a new checkpoint snapshot, save to disk
      if snap.blockNumber.isCheckPointOk and 0 < d.local.headers.len:
        var rc = snap.storeSnapshot
        if rc.isErr:
          return err(rc.error)
        trace "Stored voting snapshot to disk",
          blockNumber = d.blockNumber,
          blockHash = hash

      # clique/clique.go(438): c.recents.Add(snap.Hash, snap)
      return ok(snap)

  rs.cfg = cfg
  rs.cache.initLruCache(toKey, toValue, INMEMORY_SNAPSHOTS)


proc initRecentSnaps*(cfg: CliqueCfg): RecentSnaps {.gcsafe,raises: [Defect].} =
  result.initRecentSnaps(cfg)


proc getRecentSnaps*(rs: var RecentSnaps; args: RecentArgs): auto =
  ## Get snapshot from cache or disk
  rs.cache.getLruItem:
    RecentDesc(cfg:   rs.cfg,
               args:  args,
               local: LocalArgs())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
