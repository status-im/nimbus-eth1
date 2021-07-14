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
## Snapshot for Clique PoA Consensus Protocol
## ==========================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[sequtils, strformat, strutils],
  ../../db/db_chain,
  ../../utils,
  ./clique_cfg,
  ./clique_defs,
  ./clique_desc,
  ./snapshot/[lru_snaps, snapshot_apply, snapshot_desc],
  chronicles,
  eth/[common, keys],
  nimcrypto,
  stew/results,
  stint

type
  # Internal sub-descriptor for `LocalSnapsDesc`
  LocalPivot = object
    header:  BlockHeader
    hash:    Hash256

  # Internal sub-descriptor for `LocalSnapsDesc`
  LocalPath = object
    snaps:   Snapshot          ## snapshot for given hash
    trail:   seq[BlockHeader]  ## header chain towards snapshot
    error:   CliqueError       ## error message

  LocalSnaps = object
    c:       Clique
    start:   LocalPivot        ## start here searching for checkpoints
    value:   LocalPath         ## snapshot location
    parents: seq[BlockHeader]  ## explicit parents

{.push raises: [Defect].}

logScope:
  topics = "clique PoA snapshot"

# ------------------------------------------------------------------------------
# Private debugging functions
# ------------------------------------------------------------------------------

proc say(d: LocalSnaps; v: varargs[string,`$`]) {.inline.} =
  # d.c.cfg.say v
  discard

proc pp(q: openArray[BlockHeader]): string {.inline.} =
  "[" & toSeq(q).mapIt("#" & $it.blockNumber).join(", ") & "]"

proc pp(h: BlockHeader, q: openArray[BlockHeader]): string {.inline.} =
  "#" & $h.blockNumber & " " & q.pp

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc maxCheckPointLe(d: var LocalSnaps;
                     number: BlockNumber): BlockNumber {.inline.} =
  let epc = number mod d.c.cfg.ckpInterval
  if epc < number:
    number - epc
  else:
    # epc == number  =>  number < ckpInterval
    0.u256

proc isCheckPoint(d: var LocalSnaps;
                  number: BlockNumber): bool {.inline.} =
  (number mod d.c.cfg.ckpInterval) == 0

proc isEpoch(d: var LocalSnaps;
             number: BlockNumber): bool {.inline.} =
  (number mod d.c.cfg.epoch) == 0

proc isSnapshotPosition(d: var LocalSnaps;
                        number: BlockNumber): bool {.inline.} =
  # clique/clique.go(394): if number == 0 || (number%c.config.Epoch [..]
  if number.isZero:
    # At the genesis => snapshot the initial state.
    return true
  if d.isEpoch(number) and d.c.cfg.roThreshold < d.value.trail.len:
    # Wwe have piled up more headers than allowed to be re-orged (chain
    # reinit from a freezer), regard checkpoint trusted and snapshot it.
    return true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc findSnapshot(d: var LocalSnaps): bool
                    {.inline, gcsafe, raises: [Defect,CatchableError].} =
  ## Search for a snapshot starting at current header starting at the pivot
  ## value `ls.start`.

  var (header, hash) = (d.start.header, d.start.hash)

  while true:
    d.say "findSnapshot headers=(", header.pp(d.parents), ")"

    let number = header.blockNumber

    # Check whether the snapshot was recently visited and cahed
    if d.c.recents.hasLruSnaps(hash):
      let rc = d.c.recents.getLruSnaps(hash)
      if rc.isOK:
        # we made sure that this is not a blind entry (currently no reason
        # why there should be any, though)
        d.value.snaps = rc.value
        # d.say "findSnapshot cached headers=(", header.pp(d.value.trail), ")"
        debug "Found recently cached voting snapshot",
          blockNumber = number,
          blockHash = hash
        return true

    # If an on-disk checkpoint snapshot can be found, use that
    if d.isCheckPoint(number) and
       d.value.snaps.loadSnapshot(d.c.cfg, hash).isOK:
      d.say "findSnapshot disked trail=(", header.pp(d.value.trail), ")"
      trace "Loaded voting snapshot from disk",
        blockNumber = number,
        blockHash = hash
      # clique/clique.go(386): snap = s
      return true

    # Note that epoch is a restart and sync point. Eip-225 requires that the
    # epoch header contains the full list of currently authorised signers.
    if d.isSnapshotPosition(number):
      # clique/clique.go(395): checkpoint := chain.GetHeaderByNumber [..]
      d.value.snaps.initSnapshot(d.c.cfg, header)
      if d.value.snaps.storeSnapshot.isOK:
        d.say "findSnapshot <epoch> trail=(", header.pp(d.value.trail), ")"
        info "Stored voting snapshot to disk",
          blockNumber = number,
          blockHash = hash
        return true

    # No snapshot for this header, gather the header and move backward
    var parent: BlockHeader
    if 0 < d.parents.len:
      # If we have explicit parents, pick from there (enforced)
      parent = d.parents.pop
      # clique/clique.go(416): if header.Hash() != hash [..]
      if parent.hash != header.parentHash:
        d.value.error = (errUnknownAncestor,"")
        return false

    # No explicit parents (or no more left), reach out to the database
    elif not d.c.cfg.db.getBlockHeader(header.parentHash, parent):
      d.value.error = (errUnknownAncestor,"")
      return false

    # Add to batch (note that list order needs to be reversed later)
    d.value.trail.add header
    hash = header.parentHash
    header = parent
    # => while loop

  # notreached
  raiseAssert "findSnapshot(): wrong exit from forever-loop"


proc applyTrail(d: var LocalSnaps; snaps: var Snapshot;
                trail: seq[BlockHeader]): Result[Snapshot,CliqueError]
                  {.inline, gcsafe, raises: [Defect,CatchableError].} =
  ## Apply any `trail` headers on top of the snapshot `snap`

  # Apply trail with reversed list order
  var liart = trail
  for i in 0 ..< liart.len div 2:
    swap(liart[i], liart[^(1+i)])

  block:
    # clique/clique.go(434): snap, err := snap.apply(headers)
    let rc = snaps.snapshotApply(liart)
    if rc.isErr:
      return err(rc.error)

  # If we've generated a new checkpoint snapshot, save to disk
  if d.isCheckPoint(snaps.blockNumber) and 0 < liart.len:
    var rc = snaps.storeSnapshot
    if rc.isErr:
      return err(rc.error)

    d.say "updateSnapshot <disk> chechkpoint #", snaps.blockNumber
    trace "Stored voting snapshot to disk",
      blockNumber = snaps.blockNumber,
      blockHash = snaps.blockHash

  ok(snaps)


proc updateSnapshot(c: Clique; header: Blockheader;
              parents: openArray[Blockheader]): Result[Snapshot,CliqueError]
              {.gcsafe, raises: [Defect,CatchableError].} =
  # Initialise cache management
  var d = LocalSnaps(
    c:       c,
    parents: toSeq(parents),
    start:   LocalPivot(
      header:  header,
      hash:    header.hash))

  # For convenience, allow the top parent to be the same as the argument header
  if 0 < d.parents.len and d.parents[^1] == header:
    d.parents.setLen(d.parents.len - 1)

  # Search for previous snapshots
  if not d.findSnapshot:
    return err(d.value.error)

  # Previous snapshot found, apply any pending trail headers on top of it
  if 0 < d.value.trail.len:
    let
      first = d.value.trail[^1].blockNumber
      last  = d.value.trail[0].blockNumber
      ckpt  = d.maxCheckPointLe(last)

    # If there is at least one checkpoint part of the trail sequence, make sure
    # that we can store the latest one. This will be done by the `applyTrail()`
    # handler for the largest block number in the sequence (note that the trail
    # block numbers are in reverse order.)
    if first <= ckpt and ckpt < last:
      # Split the trail sequence so that the first one has the checkpoint
      # entry with largest block number.
      let
        inx = (last - ckpt).truncate(int)
        preTrail = d.value.trail[inx ..< d.value.trail.len]
      # Second part (note reverse block numbers.)
      d.value.trail.setLen(inx)

      let rc = d.applyTrail(d.value.snaps, preTrail)
      if rc.isErr:
        return err(rc.error)
      d.value.snaps = rc.value

  var snaps = d.applyTrail(d.value.snaps, d.value.trail)
  if snaps.isErr:
    return err(snaps.error)

  # clique/clique.go(438): c.recents.Add(snap.Hash, snap)
  if not c.recents.setLruSnaps(snaps.value):
    # someting went seriously wrong -- lol
    return err((errSetLruSnaps, &"block #{snaps.value.blockNumber}"))

  ok(snaps.value)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# clique/clique.go(369): func (c *Clique) snapshot(chain [..]
proc cliqueSnapshot*(c: Clique; header: Blockheader;
                       parents: openArray[Blockheader]): CliqueOkResult
                         {.gcsafe, raises: [Defect,CatchableError].} =
  ## Create authorisation state snapshot of a given point in the block chain
  ## and store it in the `Clique` descriptor to be retrievable as `c.snapshot`
  ## if successful.
  ##
  ## If the `parents[]` argulent list top element (if any) is the same as the
  ## `header` argument, this top element is silently ignored.
  ##
  ## A return result error (or no error) is also stored in the `Clique`
  ## descriptor to be retrievable as `c.error`.
  c.error = cliqueNoError

  let rc = c.recents.getLruSnaps(header.hash)
  if rc.isOk:
    c.snapshot = rc.value
    return ok()

  let snaps = c.updateSnapshot(header, parents)
  if snaps.isErr:
    c.error = (snaps.error)
    return err(c.error)

  c.snapshot = snaps.value
  ok()



proc cliqueSnapshot*(c: Clique; header: Blockheader): CliqueOkResult
                         {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Short for `cliqueSnapshot(c,header,@[])`
  c.cliqueSnapshot(header, @[])



proc cliqueSnapshot*(c: Clique; hash: Hash256;
                       parents: openArray[Blockheader]): CliqueOkResult
                         {.gcsafe,raises: [Defect,CatchableError].} =
  ## Create authorisation state snapshot of a given point in the block chain
  ## and store it in the `Clique` descriptor to be retrievable as  `c.snapshot`
  ## if successful.
  ##
  ## If the `parents[]` argulent list top element (if any) is the same as the
  ## `header` argument, this top element is silently ignored.
  ##
  ## A return result error (or no error) is also stored in the `Clique`
  ## descriptor to be retrievable as `c.error`.
  c.error = cliqueNoError

  let rc = c.recents.getLruSnaps(hash)
  if rc.isOk:
    c.snapshot = rc.value
    return ok()

  var header: BlockHeader
  if not c.cfg.db.getBlockHeader(hash, header):
    c.error = (errUnknownHash,"")
    return err(c.error)

  let snaps = c.updateSnapshot(header, parents)
  if snaps.isErr:
    c.error = (snaps.error)
    return err(c.error)

  c.snapshot = snaps.value
  ok()


proc cliqueSnapshot*(c: Clique; hash: Hash256): CliqueOkResult
                         {.gcsafe,raises: [Defect,CatchableError].} =
  ## Short for `cliqueSnapshot(c,hash,@[])`
  c.cliqueSnapshot(hash, @[])

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
