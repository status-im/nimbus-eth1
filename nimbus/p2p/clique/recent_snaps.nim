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
  ../../utils,
  ../../utils/lru_cache,
  ./clique_cfg,
  ./clique_defs,
  ./clique_utils,
  ./snapshot,
  chronicles,
  eth/[common, keys],
  nimcrypto,
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
    debug: bool
    args: RecentArgs
    local: LocalArgs

  RecentSnaps* = object
    cfg: CliqueCfg
    debug: bool
    cache: LruCache[RecentDesc,RecentKey,Snapshot,CliqueError]

{.push raises: [Defect].}

logScope:
  topics = "clique PoA recent-snaps"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc say(d: RecentDesc; v: varargs[string,`$`]) =
  ## Debugging output
  ppExceptionWrap:
    if d.debug:
      stderr.write "*** " & v.join & "\n"

proc say(rs: var RecentSnaps; v: varargs[string,`$`]) =
  ## Debugging output
  ppExceptionWrap:
    if rs.debug:
      stderr.write "*** " & v.join & "\n"

proc getPrettyPrinters(d: RecentDesc): var PrettyPrinters =
  ## Mixin for pretty printers, see `clique/clique_cfg.pp()`
  d.cfg.prettyPrint


proc canDiskCheckPointOk(d: RecentDesc):
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
    if d.cfg.db.getBlockHeaderResult(d.args.blockNumber - 1).isErr:
      return true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc tryLoadDiskSnapshot(d: RecentDesc; snap: var Snapshot): bool {.inline.} =
  # clique/clique.go(383): if number%checkpointInterval == 0 [..]
  if (d.args.blockNumber mod CHECKPOINT_INTERVAL) == 0:
    if snap.loadSnapshot(d.cfg, d.args.blockHash).isOk:
      trace "Loaded voting snapshot from disk",
        blockNumber = d.args.blockNumber,
        blockHash = d.args.blockHash
      return true


proc tryStoreDiskCheckPoint(d: RecentDesc; snap: var Snapshot):
                           bool {.gcsafe, raises: [Defect,RlpError].} =
  if d.canDiskCheckPointOk:
    # clique/clique.go(395): checkpoint := chain.GetHeaderByNumber [..]
    let checkPoint = d.cfg.db.getBlockHeaderResult(d.args.blockNumber)
    if checkPoint.isErr:
      return false
    let
      hash = checkPoint.value.hash
      accountList = checkPoint.value.extraData.extraDataAddresses
    snap.initSnapshot(d.cfg, d.args.blockNumber, hash, accountList)
    snap.setDebug(d.debug)

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

        else:
          # No explicit parents (or no more left), reach out to the database
          let rc = d.cfg.db.getBlockHeaderResult(d.args.blockNumber)
          if rc.isErr:
            return err((errUnknownAncestor,""))
          header = rc.value

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
        d.say "recentSnaps => applySnapshot([",
          d.local.headers.mapIt("#" & $it.blockNumber.truncate(int))
            .join(",").string, "])"
        let rc = snap.applySnapshot(d.local.headers)
        d.say "recentSnaps => applySnapshot() => ", rc.pp
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


proc initRecentSnaps*(cfg: CliqueCfg): RecentSnaps {.gcsafe,raises: [Defect].} =
  result.initRecentSnaps(cfg)


proc getRecentSnaps*(rs: var RecentSnaps; args: RecentArgs): auto {.
                     gcsafe, raises: [Defect,CatchableError].} =
  ## Get snapshot from cache or disk
  rs.say "getRecentSnap #", args.blockNumber
  rs.cache.getLruItem:
    RecentDesc(cfg:   rs.cfg,
               debug: rs.debug,
               args:  args,
               local: LocalArgs())


proc `debug=`*(rs: var RecentSnaps; debug: bool) =
  ## Setter, debugging mode on/off
  rs.debug = debug

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
