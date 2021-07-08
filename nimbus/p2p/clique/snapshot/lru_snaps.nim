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
  std/[sequtils, strutils],
  ../../../db/db_chain,
  ../../../utils,
  ../../../utils/lru_cache,
  ../clique_cfg,
  ../clique_defs,
  ../clique_utils,
  ./snapshot_desc,
  ./snapshot_apply,
  chronicles,
  eth/[common, keys],
  nimcrypto,
  stew/results,
  stint

export
  results,
  snapshot_desc

type
  LruSnapsArgs* = ref object
    blockHash*: Hash256
    blockNumber*: BlockNumber
    parents*: seq[BlockHeader]

  # Internal, temporary state variables
  LocalArgs = ref object
    headers: seq[BlockHeader]

  # Internal type, simplify Hash256 for rlp serialisation
  LruSnapsKey = array[32, byte]

  # Internal descriptor used by toValue()
  LruSnapsDesc = object
    cfg: CliqueCfg
    debug: bool
    args: LruSnapsArgs
    local: LocalArgs

  LruSnaps* = object
    cfg: CliqueCfg
    debug: bool
    cache: LruCache[LruSnapsDesc,LruSnapsKey,Snapshot,CliqueError]

{.push raises: [Defect].}

logScope:
  topics = "clique PoA lru-snaps"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc say(d: LruSnapsDesc; v: varargs[string,`$`]) =
  ## Debugging output
  ppExceptionWrap:
    if d.debug:
      stderr.write "*** " & v.join & "\n"

proc say(rs: var LruSnaps; v: varargs[string,`$`]) =
  ## Debugging output
  ppExceptionWrap:
    if rs.debug:
      stderr.write "*** " & v.join & "\n"

proc getPrettyPrinters(d: LruSnapsDesc): var PrettyPrinters =
  ## Mixin for pretty printers, see `clique/clique_cfg.pp()`
  d.cfg.prettyPrint


proc canDiskCheckPointOk(d: LruSnapsDesc):
                        bool {.inline, raises: [Defect,RlpError].} =

  # clique/clique.go(394): if number == 0 || (number%c.config.Epoch [..]
  if d.args.blockNumber.isZero:
    # If we're at the genesis, snapshot the initial state.
    return true

  if (d.args.blockNumber mod d.cfg.epoch) == 0:
    # Alternatively if we're at a checkpoint block without a parent
    # (light client CHT), or we have piled up more headers than allowed
    # to be re-orged (chain reinit from a freezer), consider the
    # checkpoint trusted and snapshot it.
    if FULL_IMMUTABILITY_THRESHOLD < d.local.headers.len:
      return true
    var ignore: BlockHeader
    if not d.cfg.db.getBlockHeader(d.args.blockNumber - 1, ignore):
      return true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc tryLoadDiskSnapshot(d: LruSnapsDesc; snap: var Snapshot): bool {.inline.} =
  # clique/clique.go(383): if number%checkpointInterval == 0 [..]
  if (d.args.blockNumber mod CHECKPOINT_INTERVAL) == 0:
    if snap.loadSnapshot(d.cfg, d.args.blockHash).isOk:
      trace "Loaded voting snapshot from disk",
        blockNumber = d.args.blockNumber,
        blockHash = d.args.blockHash
      return true


proc tryStoreDiskCheckPoint(d: LruSnapsDesc; snap: var Snapshot):
                           bool {.gcsafe, raises: [Defect,RlpError].} =
  if d.canDiskCheckPointOk:
    # clique/clique.go(395): checkpoint := chain.GetHeaderByNumber [..]
    var checkPoint: BlockHeader
    if not d.cfg.db.getBlockHeader(d.args.blockNumber, checkPoint):
      return false
    let
      hash = checkPoint.hash
      accountList = checkPoint.extraData.extraDataAddresses
    snap.initSnapshot(d.cfg, d.args.blockNumber, hash, accountList)
    snap.debug = d.debug

    if snap.storeSnapshot.isOk:
      info "Stored checkpoint snapshot to disk",
        blockNumber = d.args.blockNumber,
        blockHash = hash
      return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc initLruSnaps*(rs: var LruSnaps;
                      cfg: CliqueCfg) {.gcsafe,raises: [Defect].} =

  var toKey: LruKey[LruSnapsDesc,LruSnapsKey] =
    proc(d: LruSnapsDesc): LruSnapsKey =
      d.args.blockHash.data

  var toValue: LruValue[LruSnapsDesc,Snapshot,CliqueError] =
    proc(d: LruSnapsDesc): Result[Snapshot,CliqueError] =
      var snap: Snapshot

      while true:
        # If an on-disk checkpoint snapshot can be found, use that
        if d.tryLoadDiskSnapshot(snap):
          # clique/clique.go(386): snap = s
          break

        # Save checkpoint e.g. when at the genesis ..
        if d.tryStoreDiskCheckPoint(snap):
          # clique/clique.go(407): log.Info("Stored [..]
          break

        # No snapshot for this header, gather the header and move backward
        var header: BlockHeader
        if 0 < d.args.parents.len:
          # If we have explicit parents, pick from there (enforced)
          header = d.args.parents[^1]

          # clique/clique.go(416): if header.Hash() != hash [..]
          if header.hash        != d.args.blockHash or
             header.blockNumber != d.args.blockNumber:
            return err((errUnknownAncestor,""))
          d.args.parents.setLen(d.args.parents.len-1)

        # No explicit parents (or no more left), reach out to the database
        elif not d.cfg.db.getBlockHeader(d.args.blockNumber, header):
          return err((errUnknownAncestor,""))

        # Add to batch (note that list order needs to be reversed later)
        d.local.headers.add header
        d.args.blockNumber -= 1.u256
        d.args.blockHash = header.parentHash
        # => while loop

      # Previous snapshot found, apply any pending headers on top of it
      for i in 0 ..< d.local.headers.len div 2:
        # Reverse list order
        swap(d.local.headers[i], d.local.headers[^(1+i)])
      block:
        # clique/clique.go(434): snap, err := snap.apply(headers)
        d.say "lruSnaps => applySnapshot([",
          d.local.headers.mapIt("#" & $it.blockNumber.truncate(int))
            .join(",").string, "])"
        let rc = snap.snapshotApply(d.local.headers)
        d.say "lruSnaps => applySnapshot() => ", rc.pp
        if rc.isErr:
          return err(rc.error)

      # If we've generated a new checkpoint snapshot, save to disk
      if (snap.blockNumber mod CHECKPOINT_INTERVAL) == 0 and
         0 < d.local.headers.len:
        var rc = snap.storeSnapshot
        if rc.isErr:
          return err(rc.error)
        trace "Stored voting snapshot to disk",
          blockNumber = snap.blockNumber,
          blockHash = snap.blockHash

      # clique/clique.go(438): c.recents.Add(snap.Hash, snap)
      return ok(snap)

  rs.cfg = cfg
  rs.cache.initLruCache(toKey, toValue, INMEMORY_SNAPSHOTS)


proc initLruSnaps*(cfg: CliqueCfg): LruSnaps {.gcsafe,raises: [Defect].} =
  result.initLruSnaps(cfg)


#proc getLruSnaps*(rs: var LruSnaps; args: LruSnapsArgs): SnapshotResult
#                     {.gcsafe, raises: [Defect,CatchableError].} =
#  ## Get snapshot from cache or disk
#  rs.say "getLruSnap #", args.blockNumber
#  rs.cache.getLruItem:
#    LruSnapsDesc(cfg:   rs.cfg,
#                 debug: rs.debug,
#                 args:  args,
#                 local: LocalArgs())

proc getLruSnaps*(rs: var LruSnaps; header: BlockHeader;
                  parents: openArray[Blockheader]): SnapshotResult
                     {.gcsafe, raises: [Defect,CatchableError].} =
  ## Get snapshot from cache or disk
  rs.say "getLruSnap #", header.blockNumber
  rs.cache.getLruItem:
    LruSnapsDesc(
      cfg:   rs.cfg,
      debug: rs.debug,
      local: LocalArgs(),
      args:  LruSnapsArgs(
        blockHash:   header.hash,
        blockNumber: header.blockNumber,
        parents:     toSeq(parents)))


proc `debug=`*(rs: var LruSnaps; debug: bool) =
  ## Setter, debugging mode on/off
  rs.debug = debug

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
