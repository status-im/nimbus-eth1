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
    chain:   seq[BlockHeader]  ## header chain towards snapshot
    error:   CliqueError       ## error message

  # Internal sub-descriptor for `LocalSnapsDesc`
  LocalSubChain = object
    first:   int               ## first chain[] element to be used
    top:     int               ## length of chain starting at position 0

  LocalSnaps = object
    c:       Clique
    start:   LocalPivot        ## start here searching for checkpoints
    trail:   LocalPath         ## snapshot location
    subChn:  LocalSubChain     ## chain[] sub-range
    parents: seq[BlockHeader]  ## explicit parents

{.push raises: [Defect].}

logScope:
  topics = "clique PoA snapshot"

# ------------------------------------------------------------------------------
# Private debugging functions, pretty printing
# ------------------------------------------------------------------------------

proc say(d: LocalSnaps; v: varargs[string,`$`]) {.inline.} =
  # d.c.cfg.say v
  discard


proc pp(q: openArray[BlockHeader]; n: int): string {.inline.} =
  "[" & toSeq(q[0 ..< n]).mapIt("#" & $it.blockNumber).join(", ") & "]"

proc pp(b: BlockNumber, q: openArray[BlockHeader]; n: int): string {.inline.} =
  "#" & $b & " + " & q.pp(n)


proc pp(q: openArray[BlockHeader]): string {.inline.} =
  q.pp(q.len)

proc pp(b: BlockNumber, q: openArray[BlockHeader]): string {.inline.} =
  b.pp(q, q.len)


proc pp(h: BlockHeader, q: openArray[BlockHeader]; n: int): string {.inline.} =
  "headers=(" & h.blockNumber.pp(q,n) & ")"

proc pp(h: BlockHeader, q: openArray[BlockHeader]): string {.inline.} =
  h.pp(q,q.len)

proc pp(t: var LocalPath; w: var LocalSubChain): string {.inline.} =
  var (a, b) = (w.first, w.top)
  if a == 0 and b == 0: b = t.chain.len
  "trail=(#" & $t.snaps.blockNumber & " + " & t.chain[a ..< b].pp & ")"

proc pp(t: var LocalPath): string {.inline.} =
  var w = LocalSubChain()
  t.pp(w)

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
  if d.isEpoch(number) and d.c.cfg.roThreshold < d.trail.chain.len:
    # Wwe have piled up more headers than allowed to be re-orged (chain
    # reinit from a freezer), regard checkpoint trusted and snapshot it.
    return true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc findSnapshot(d: var LocalSnaps): bool
                    {.inline, gcsafe, raises: [Defect,CatchableError].} =
  ## Search for a snapshot starting at current header starting at the pivot
  ## value `d.start`. The snapshot returned in `trail` is a clone of the
  ## cached snapshot and can be modified later.

  var
    (header, hash) = (d.start.header, d.start.hash)
    parentsLen = d.parents.len

  # For convenience, ignore the current header as top parents list entry
  if 0 < parentsLen and d.parents[^1] == header:
    parentsLen.dec

  while true:
    d.say "findSnapshot ", header.pp(d.parents, parentsLen)
    let number = header.blockNumber

    # Check whether the snapshot was recently visited and cahed
    if d.c.recents.hasLruSnaps(hash):
      let rc = d.c.recents.getLruSnaps(hash)
      if rc.isOK:
        # we made sure that this is not a blind entry (currently no reason
        # why there should be any, though)
        d.trail.snaps = rc.value.cloneSnapshot
        # d.say "findSnapshot cached ", d.trail.pp
        debug "Found recently cached voting snapshot",
          blockNumber = number,
          blockHash = hash
        return true

    # If an on-disk checkpoint snapshot can be found, use that
    if d.isCheckPoint(number):
      let rc = d.c.cfg.loadSnapshot(hash)
      if rc.isOk:
        d.trail.snaps = rc.value.cloneSnapshot
        d.say "findSnapshot disked ", d.trail.pp
        trace "Loaded voting snapshot from disk",
          blockNumber = number,
          blockHash = hash
        # clique/clique.go(386): snap = s
        return true

    # Note that epoch is a restart and sync point. Eip-225 requires that the
    # epoch header contains the full list of currently authorised signers.
    if d.isSnapshotPosition(number):
      # clique/clique.go(395): checkpoint := chain.GetHeaderByNumber [..]
      d.trail.snaps = d.c.cfg.newSnapshot(header)
      if d.trail.snaps.storeSnapshot.isOK:
        d.say "findSnapshot <epoch> ", d.trail.pp
        info "Stored voting snapshot to disk",
          blockNumber = number,
          blockHash = hash
        return true

    # No snapshot for this header, get the parent header and move backward
    hash = header.parentHash
    # Add to batch (reversed list order, biggest block number comes first)
    d.trail.chain.add header

    # Assign parent header
    if 0 < parentslen:
      # If we have explicit parents, pop it from the parents list
      parentsLen.dec
      header = d.parents[parentsLen]
      # clique/clique.go(416): if header.Hash() != hash [..]
      if header.hash != hash:
        d.trail.error = (errUnknownAncestor,"")
        return false

    # No explicit parents (or no more parents left), reach out to the database
    elif not d.c.cfg.db.getBlockHeader(hash, header):
      d.trail.error = (errUnknownAncestor,"")
      return false

    # => while loop

  # notreached
  raiseAssert "findSnapshot(): wrong exit from forever-loop"


proc applyTrail(d: var LocalSnaps): CliqueOkResult
                  {.inline, gcsafe, raises: [Defect,CatchableError].} =
  ## Apply any `trail` headers on top of the snapshot `snap`
  if d.subChn.first < d.subChn.top:
    block:
      # clique/clique.go(434): snap, err := snap.apply(headers)
      d.say "applyTrail ", d.trail.pp(d.subChn)
      let rc = d.trail.snaps.snapshotApply(
        d.trail.chain, d.subChn.top-1, d.subChn.first)
      if rc.isErr:
        return err(rc.error)

    # If we've generated a new checkpoint snapshot, save to disk
    if d.isCheckPoint(d.trail.snaps.blockNumber):

      var rc = d.trail.snaps.storeSnapshot
      if rc.isErr:
        return err(rc.error)

      d.say "updateSnapshot <disk> chechkpoint #", d.trail.snaps.blockNumber
      trace "Stored voting snapshot to disk",
         blockNumber = d.trail.snaps.blockNumber,
         blockHash = d.trail.snaps.blockHash
  ok()


proc updateSnapshot(d: var LocalSnaps): Result[Snapshot,CliqueError]
                   {.gcsafe, raises: [Defect,CatchableError].} =
  ## Find snapshot for header `d.start.header` and assign it to the LRU cache.
  ## This function was expects thet the LRU cache already has a slot allocated
  ## for the snapshot having run `getLruSnaps()`.

  # Search for previous snapshots
  if not d.findSnapshot:
    return err(d.trail.error)

  # Initialise range for header chain[] to be applied to `d.trail.snaps`
  d.subChn.top = d.trail.chain.len

  # Previous snapshot found, apply any pending trail headers on top of it
  if 0 < d.subChn.top:
    let
      first = d.trail.chain[^1].blockNumber
      last  = d.trail.chain[0].blockNumber
      ckpt  = d.maxCheckPointLe(last)

    # If there is at least one checkpoint part of the trail sequence, make sure
    # that we can store the latest one. This will be done by the `applyTrail()`
    # handler for the largest block number in the sequence (note that the trail
    # block numbers are in reverse order.)
    if first <= ckpt and ckpt < last:
      # Split the trail sequence so that the first one has the checkpoint
      # entry with largest block number.
      let inx = (last - ckpt).truncate(int)

      # First part (note reverse block numbers.)
      d.subChn.first = inx
      let rc = d.applyTrail
      if rc.isErr:
        return err(rc.error)

      # Second part (note reverse block numbers.)
      d.subChn.first = 0
      d.subChn.top = inx

  var rc = d.applyTrail
  if rc.isErr:
    return err(rc.error)

  # clique/clique.go(438): c.recents.Add(snap.Hash, snap)
  if not d.c.recents.setLruSnaps(d.trail.snaps):
    # Someting went seriously wrong, most probably this function was called
    # before checking the LRU cache first -- lol
    return err((errSetLruSnaps, &"block #{d.trail.snaps.blockNumber}"))

  ok(d.trail.snaps)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# clique/clique.go(369): func (c *Clique) snapshot(chain [..]
proc cliqueSnapshot*(c: Clique; header: Blockheader;
                     parents: var seq[Blockheader]): CliqueOkResult
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

  # Avoid deep copy, sequence will not be changed by `updateSnapshot()`
  parents.shallow

  var d = LocalSnaps(
    c:       c,
    parents: parents,
    start:   LocalPivot(
      header:  header,
      hash:    header.hash))

  let snaps = d.updateSnapshot
  if snaps.isErr:
    c.error = (snaps.error)
    return err(c.error)

  c.snapshot = snaps.value
  ok()



proc cliqueSnapshot*(c: Clique; header: Blockheader): CliqueOkResult
                         {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Short for `cliqueSnapshot(c,header,@[])`
  var blind: seq[Blockheader]
  c.cliqueSnapshot(header, blind)



proc cliqueSnapshot*(c: Clique; hash: Hash256;
                     parents: var seq[Blockheader]): CliqueOkResult
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

  # Avoid deep copy, sequence will not be changed by `updateSnapshot()`
  parents.shallow

  var d = LocalSnaps(
    c:       c,
    parents: toSeq(parents),
    start:   LocalPivot(
      header:  header,
      hash:    header.hash))

  let snaps = d.updateSnapshot
  if snaps.isErr:
    c.error = (snaps.error)
    return err(c.error)

  c.snapshot = snaps.value
  ok()


proc cliqueSnapshot*(c: Clique; hash: Hash256): CliqueOkResult
                         {.gcsafe,raises: [Defect,CatchableError].} =
  ## Short for `cliqueSnapshot(c,hash,@[])`
  var blind: seq[Blockheader]
  c.cliqueSnapshot(hash, blind)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
