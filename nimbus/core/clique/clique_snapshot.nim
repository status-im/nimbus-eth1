# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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
  std/[sequtils, strutils],
  chronicles,
  eth/[keys],
  stew/[keyed_queue, results],
  ../../utils/prettify,
  "."/[clique_cfg, clique_defs, clique_desc],
  ./snapshot/[snapshot_apply, snapshot_desc]

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
    parents: HeadersHolderRef  ## explicit parents

  HeadersHolderRef* = ref object
    headers*: seq[BlockHeader]

{.push raises: [].}

logScope:
  topics = "clique PoA snapshot"

static:
  const stopCompilerGossip {.used.} = 42.toSI

# ------------------------------------------------------------------------------
# Private debugging functions, pretty printing
# ------------------------------------------------------------------------------

template say(d: var LocalSnaps; v: varargs[untyped]): untyped =
  discard
  # uncomment body to enable, note that say() prints on <stderr>
  # d.c.cfg.say v

#proc pp(a: Hash256): string =
#  if a == EMPTY_ROOT_HASH:
#    "*blank-root*"
#  elif a == EMPTY_SHA3:
#    "*empty-sha3*"
#  else:
#    a.data.mapIt(it.toHex(2)).join[56 .. 63].toLowerAscii

#proc pp(q: openArray[BlockHeader]; n: int): string =
#  result = "["
#  if 5 < n:
#    result &= toSeq(q[0 .. 2]).mapIt("#" & $it.blockNumber).join(", ")
#    result &= " .." & $n &  ".. #" & $q[n-1].blockNumber
#  else:
#    result &= toSeq(q[0 ..< n]).mapIt("#" & $it.blockNumber).join(", ")
#  result &= "]"

#proc pp(b: BlockNumber, q: openArray[BlockHeader]; n: int): string =
#  "#" & $b & " + " & q.pp(n)


#proc pp(q: openArray[BlockHeader]): string =
#  q.pp(q.len)

#proc pp(b: BlockNumber, q: openArray[BlockHeader]): string =
#  b.pp(q, q.len)


#proc pp(h: BlockHeader, q: openArray[BlockHeader]; n: int): string =
#  "headers=(" & h.blockNumber.pp(q,n) & ")"

#proc pp(h: BlockHeader, q: openArray[BlockHeader]): string =
#  h.pp(q,q.len)

#proc pp(t: var LocalPath; w: var LocalSubChain): string =
#  var (a, b) = (w.first, w.top)
#  if a == 0 and b == 0: b = t.chain.len
#  "trail=(#" & $t.snaps.blockNumber & " + " & t.chain[a ..< b].pp & ")"

#proc pp(t: var LocalPath): string =
#  var w = LocalSubChain()
#  t.pp(w)

#proc pp(err: CliqueError): string =
#  "(" & $err[0] & "," & err[1] & ")"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc maxCheckPointLe(d: var LocalSnaps; number: BlockNumber): BlockNumber =
  let epc = number mod d.c.cfg.ckpInterval
  if epc < number:
    number - epc
  else:
    # epc == number  =>  number < ckpInterval
    0.u256

proc isCheckPoint(d: var LocalSnaps; number: BlockNumber): bool =
  (number mod d.c.cfg.ckpInterval).isZero

proc isEpoch(d: var LocalSnaps; number: BlockNumber): bool =
  (number mod d.c.cfg.epoch).isZero

proc isSnapshotPosition(d: var LocalSnaps; number: BlockNumber): bool =
  # clique/clique.go(394): if number == 0 || (number%c.config.Epoch [..]
  if d.isEpoch(number):
    if number.isZero:
      # At the genesis => snapshot the initial state.
      return true
    if not d.c.applySnapsMinBacklog:
      return true
    if d.c.cfg.roThreshold < d.trail.chain.len:
      # We have piled up more headers than allowed to be re-orged (chain
      # reinit from a freezer), regard checkpoint trusted and snapshot it.
      return true

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func len*(list: HeadersHolderRef): int =
  list.headers.len

func `[]`*(list: HeadersHolderRef, idx: int): BlockHeader =
  list.headers[idx]

func `[]`*(list: HeadersHolderRef, idx: BackwardsIndex): BlockHeader =
  list.headers[list.headers.len - int(idx)]

proc findSnapshot(d: var LocalSnaps): bool =
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
    #d.say "findSnapshot ", header.pp(d.parents, parentsLen),
    #  " trail=", d.trail.chain.pp

    let number = header.blockNumber

    # Check whether the snapshot was recently visited and cached
    block:
      let rc = d.c.recents.lruFetch(hash.data)
      if rc.isOk:
        d.trail.snaps = rc.value.cloneSnapshot
        # d.say "findSnapshot cached ", d.trail.pp
        trace "Found recently cached voting snapshot",
          blockNumber = number,
          blockHash = hash
        return true

    # If an on-disk checkpoint snapshot can be found, use that
    if d.isCheckPoint(number):
      let rc = d.c.cfg.loadSnapshot(hash)
      if rc.isOk:
        d.trail.snaps = rc.value.cloneSnapshot
        d.say "findSnapshot on disk ", d.trail.pp
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
      let rc = d.c.cfg.storeSnapshot(d.trail.snaps)
      if rc.isOk:
        d.say "findSnapshot <epoch> ", d.trail.pp
        trace "Stored voting snapshot to disk",
          blockNumber = number,
          blockHash = hash,
          nSnaps = d.c.cfg.nSnaps,
          snapsTotal = d.c.cfg.snapsData.toSI
        return true

    # No snapshot for this header, get the parent header and move backward
    hash = header.parentHash
    # Add to batch (reversed list order, biggest block number comes first)
    d.trail.chain.add header

    # Assign parent header
    if 0 < parentsLen:
      # If we have explicit parents, pop it from the parents list
      parentsLen.dec
      header = d.parents[parentsLen]
      # clique/clique.go(416): if header.Hash() != hash [..]
      if header.blockHash != hash:
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
    {.gcsafe, raises: [CatchableError].} =
  ## Apply any `trail` headers on top of the snapshot `snap`
  if d.subChn.first < d.subChn.top:
    block:
      # clique/clique.go(434): snap, err := snap.apply(headers)
      d.say "applyTrail ", d.trail.pp(d.subChn)
      let rc = d.trail.snaps.snapshotApplySeq(
        d.trail.chain, d.subChn.top-1, d.subChn.first)
      if rc.isErr:
        d.say "applyTrail snaps=#", d.trail.snaps.blockNumber,
          " err=", rc.error.pp
        return err(rc.error)
      d.say "applyTrail snaps=#", d.trail.snaps.blockNumber

    # If we've generated a new checkpoint snapshot, save to disk
    if d.isCheckPoint(d.trail.snaps.blockNumber):

      var rc = d.c.cfg.storeSnapshot(d.trail.snaps)
      if rc.isErr:
        return err(rc.error)

      d.say "applyTrail <disk> chechkpoint #", d.trail.snaps.blockNumber
      trace "Stored voting snapshot to disk",
         blockNumber = d.trail.snaps.blockNumber,
         blockHash = d.trail.snaps.blockHash,
         nSnaps = d.c.cfg.nSnaps,
         snapsTotal = d.c.cfg.snapsData.toSI
  ok()


proc updateSnapshot(d: var LocalSnaps): SnapshotResult
    {.gcsafe, raises: [CatchableError].} =
  ## Find snapshot for header `d.start.header` and assign it to the LRU cache.
  ## This function was expects thet the LRU cache already has a slot allocated
  ## for the snapshot having run `getLruSnaps()`.

  d.say "updateSnapshot begin ", d.start.header.blockNumber.pp(d.parents)

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
  discard d.c.recents.lruAppend(
    d.trail.snaps.blockHash.data, d.trail.snaps, INMEMORY_SNAPSHOTS)

  if 1 < d.trail.chain.len:
    d.say "updateSnapshot ok #", d.trail.snaps.blockNumber,
      " trail.len=", d.trail.chain.len

  ok(d.trail.snaps)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc cliqueSnapshotSeq*(c: Clique; header: BlockHeader;
                        parents: HeadersHolderRef): SnapshotResult
                           {.gcsafe, raises: [CatchableError].} =
  ## Create authorisation state snapshot of a given point in the block chain
  ## and store it in the `Clique` descriptor to be retrievable as `c.snapshot`
  ## if successful.
  ##
  ## If the `parents[]` argument list top element (if any) is the same as the
  ## `header` argument, this top element is silently ignored.
  ##
  ## If this function is successful, the compiled `Snapshot` will also be
  ## stored in the `Clique` descriptor which can be retrieved later
  ## via `c.snapshot`.
  block:
    let rc = c.recents.lruFetch(header.blockHash.data)
    if rc.isOk:
      c.snapshot = rc.value
      return ok(rc.value)

  # Avoid deep copy, sequence will not be changed by `updateSnapshot()`

  var snaps = LocalSnaps(
    c:       c,
    parents: parents,
    start:   LocalPivot(
      header:  header,
      hash:    header.blockHash))

  let rc = snaps.updateSnapshot
  if rc.isOk:
    c.snapshot = rc.value

  rc


proc cliqueSnapshotSeq*(c: Clique; hash: Hash256;
                        parents: HeadersHolderRef): SnapshotResult
                          {.gcsafe,raises: [CatchableError].} =
  ## Create authorisation state snapshot of a given point in the block chain
  ## and store it in the `Clique` descriptor to be retrievable as  `c.snapshot`
  ## if successful.
  ##
  ## If the `parents[]` argument list top element (if any) is the same as the
  ## `header` argument, this top element is silently ignored.
  ##
  ## If this function is successful, the compiled `Snapshot` will also be
  ## stored in the `Clique` descriptor which can be retrieved later
  ## via `c.snapshot`.
  block:
    let rc = c.recents.lruFetch(hash.data)
    if rc.isOk:
      c.snapshot = rc.value
      return ok(rc.value)

  var header: BlockHeader
  if not c.cfg.db.getBlockHeader(hash, header):
    return err((errUnknownHash,""))

  # Avoid deep copy, sequence will not be changed by `updateSnapshot()`

  var snaps = LocalSnaps(
    c:       c,
    parents: parents,
    start:   LocalPivot(
      header:  header,
      hash:    hash))

  let rc = snaps.updateSnapshot
  if rc.isOk:
    c.snapshot = rc.value

  rc


# clique/clique.go(369): func (c *Clique) snapshot(chain [..]
proc cliqueSnapshot*(c: Clique; header: BlockHeader;
                     parents: var seq[BlockHeader]): SnapshotResult
                         {.gcsafe, raises: [CatchableError].} =
  let list = HeadersHolderRef(
    headers: toSeq(parents)
  )
  c.cliqueSnapshotSeq(header,list)

proc cliqueSnapshot*(c: Clique;hash: Hash256;
                     parents: openArray[BlockHeader]): SnapshotResult
                         {.gcsafe, raises: [CatchableError].} =
  let list = HeadersHolderRef(
    headers: toSeq(parents)
  )
  c.cliqueSnapshotSeq(hash,list)

proc cliqueSnapshot*(c: Clique; header: BlockHeader): SnapshotResult
                         {.gcsafe,raises: [CatchableError].} =
  ## Short for `cliqueSnapshot(c,header,@[])`
  let blind = HeadersHolderRef()
  c.cliqueSnapshotSeq(header, blind)

proc cliqueSnapshot*(c: Clique; hash: Hash256): SnapshotResult
                         {.gcsafe,raises: [CatchableError].} =
  ## Short for `cliqueSnapshot(c,hash,@[])`
  let blind = HeadersHolderRef()
  c.cliqueSnapshotSeq(hash, blind)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
