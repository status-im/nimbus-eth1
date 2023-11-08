# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB records transaction based merge test

import
  std/[algorithm, bitops, sequtils, sets, tables],
  eth/common,
  results,
  unittest2,
  stew/endians2,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_debug, aristo_delete, aristo_desc, aristo_get,
    aristo_merge],
  ../../nimbus/db/[aristo, aristo/aristo_init/persistent],
  ../replay/xcheck,
  ./test_helpers

type
  PrngDesc = object
    prng: uint32                       ## random state

  KnownHasherFailure* = seq[(string,(int,AristoError))]
    ## (<sample-name> & "#" <instance>, (<vertex-id>,<error-symbol>))

const
  MaxFilterBulk = 150_000
    ## Policy settig for `pack()`

  WalkStopErr =
    Result[LeafTie,(VertexID,AristoError)].err((VertexID(0),NearbyBeyondRange))

let
  TxQidLyo = QidSlotLyo.to(QidLayoutRef)
    ## Cascaded filter slots layout for testing

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc posixPrngRand(state: var uint32): byte =
  ## POSIX.1-2001 example of a rand() implementation, see manual page rand(3).
  state = state * 1103515245 + 12345;
  let val = (state shr 16) and 32767    # mod 2^31
  (val shr 8).byte                      # Extract second byte

proc rand[W: SomeInteger|VertexID](ap: var PrngDesc; T: type W): T =
  var a: array[sizeof T,byte]
  for n in 0 ..< sizeof T:
    a[n] = ap.prng.posixPrngRand().byte
  when sizeof(T) == 1:
    let w = uint8.fromBytesBE(a).T
  when sizeof(T) == 2:
    let w = uint16.fromBytesBE(a).T
  when sizeof(T) == 4:
    let w = uint32.fromBytesBE(a).T
  else:
    let w = uint64.fromBytesBE(a).T
  when T is SomeUnsignedInt:
    # That way, `fromBytesBE()` can be applied to `uint`
    result = w
  else:
    # That way the result is independent of endianness
    (addr result).copyMem(unsafeAddr w, sizeof w)

proc init(T: type PrngDesc; seed: int): PrngDesc =
  result.prng = (seed and 0x7fffffff).uint32

proc rand(td: var PrngDesc; top: int): int =
  if 0 < top:
    let mask = (1 shl (8 * sizeof(int) - top.countLeadingZeroBits)) - 1
    for _ in 0 ..< 100:
      let w = mask and td.rand(typeof(result))
      if w < top:
        return w
    raiseAssert "Not here (!)"

# -----------------------

proc randomisedLeafs(
    db: AristoDbRef;
    td: var PrngDesc;
       ): seq[(LeafTie,VertexID)] =
  result = db.top.lTab.pairs.toSeq.filterIt(it[1].isvalid).sorted(
    cmp = proc(a,b: (LeafTie,VertexID)): int = cmp(a[0], b[0]))
  if 2 < result.len:
    for n in 0 ..< result.len-1:
      let r = n + td.rand(result.len - n)
      result[n].swap result[r]

proc innerCleanUp(db: AristoDbRef): bool {.discardable.}  =
  ## Defer action
  let rx = db.txTop()
  if rx.isOk:
    let rc = rx.value.collapse(commit=false)
    xCheckRc rc.error == 0
  db.finish(flush=true)

proc saveToBackend(
    tx: var AristoTxRef;
    chunkedMpt: bool;
    relax: bool;
    noisy: bool;
    debugID: int;
      ): bool =
  var db = tx.to(AristoDbRef)

  # Verify context: nesting level must be 2 (i.e. two transactions)
  xCheck tx.level == 2

  block:
    let rc = db.checkTop(relax=true)
    xCheckRc rc.error == (0,0)

  # Commit and hashify the current layer
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  # Make sure MPT hashes are OK
  xCheck db.top.dirty == false

  block:
    let rc = db.txTop()
    xCheckRc rc.error == 0
    tx = rc.value

  # Verify context: nesting level must be 1 (i.e. one transaction)
  xCheck tx.level == 1

  block:
    let rc = db.checkBE(relax=true)
    xCheckRc rc.error == (0,0)

  # Commit and save to backend
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  # Make sure MPT hashes are OK
  xCheck db.top.dirty == false

  block:
    let rc = db.txTop()
    xCheckErr rc.value.level < 0 # force error

  block:
    let rc = db.stow(stageLimit=MaxFilterBulk, chunkedMpt=chunkedMpt)
    xCheckRc rc.error == 0

  block:
    let rc = db.checkBE(relax=relax)
    xCheckRc rc.error == (0,0)

  # Update layers to original level
  tx = db.txBegin().value.to(AristoDbRef).txBegin().value

  true

proc saveToBackendWithOops(
    tx: var AristoTxRef;
    chunkedMpt: bool;
    noisy: bool;
    debugID: int;
    oops: (int,AristoError);
      ): bool =
  var db = tx.to(AristoDbRef)

  # Verify context: nesting level must be 2 (i.e. two transactions)
  xCheck tx.level == 2

  # Commit and hashify the current layer
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  # Make sure MPT hashes are OK
  xCheck db.top.dirty == false

  block:
    let rc = db.txTop()
    xCheckRc rc.error == 0
    tx = rc.value

  # Verify context: nesting level must be 1 (i.e. one transaction)
  xCheck tx.level == 1

  # Commit and save to backend
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  # Make sure MPT hashes are OK
  xCheck db.top.dirty == false

  block:
    let rc = db.txTop()
    xCheckErr rc.value.level < 0 # force error

  block:
    let rc = db.stow(stageLimit=MaxFilterBulk, chunkedMpt=chunkedMpt)
    xCheckRc rc.error == 0

  # Update layers to original level
  tx = db.txBegin().value.to(AristoDbRef).txBegin().value

  true


proc fwdWalkVerify(
    db: AristoDbRef;
    root: VertexID;
    leftOver: HashSet[LeafTie];
    noisy: bool;
    debugID: int;
      ): bool =
  let
    nLeafs = leftOver.len
  var
    leftOver = leftOver
    last = LeafTie()
    n = 0
  for (key,_) in db.right low(LeafTie,root):
    xCheck key in leftOver:
      noisy.say "*** fwdWalkVerify", "id=", n + (nLeafs + 1) * debugID
    leftOver.excl key
    last = key
    n.inc

  # Verify stop condition
  if last.root == VertexID(0):
    last = low(LeafTie,root)
  elif last != high(LeafTie,root):
    last = last.next
  let rc = last.right db
  xCheck rc.isErr
  xCheck rc.error[1] == NearbyBeyondRange
  xCheck n == nLeafs

  true

proc revWalkVerify(
    db: AristoDbRef;
    root: VertexID;
    leftOver: HashSet[LeafTie];
    noisy: bool;
    debugID: int;
      ): bool =
  let
    nLeafs = leftOver.len
  var
    leftOver = leftOver
    last = LeafTie()
    n = 0
  for (key,_) in db.left high(LeafTie,root):
    xCheck key in leftOver:
      noisy.say "*** revWalkVerify", " id=", n + (nLeafs + 1) * debugID
    leftOver.excl key
    last = key
    n.inc

  # Verify stop condition
  if last.root == VertexID(0):
    last = high(LeafTie,root)
  elif last != low(LeafTie,root):
    last = last.prev
  let rc = last.left db
  xCheck rc.isErr
  xCheck rc.error[1] == NearbyBeyondRange
  xCheck n == nLeafs

  true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testTxMergeAndDelete*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  var
    prng = PrngDesc.init 42
    db = AristoDbRef()
    fwdRevVfyToggle = true
  defer:
    db.finish(flush=true)

  for n,w in list:
    # Start with brand new persistent database.
    db = block:
      if 0 < rdbPath.len:
        let rc = AristoDbRef.init(RdbBackendRef, rdbPath, qidLayout=TxQidLyo)
        xCheckRc rc.error == 0
        rc.value
      else:
        AristoDbRef.init(MemBackendRef, qidLayout=TxQidLyo)

    # Start transaction (double frame for testing)
    xCheck db.txTop.isErr
    var tx = db.txBegin().value.to(AristoDbRef).txBegin().value
    xCheck tx.isTop()
    xCheck tx.level == 2

    # Reset database so that the next round has a clean setup
    defer: db.innerCleanUp

    # Merge leaf data into main trie (w/vertex ID 1)
    let kvpLeafs = w.kvpLst.mapRootVid VertexID(1)
    for leaf in kvpLeafs:
      let rc = db.merge leaf
      xCheckRc rc.error == 0

    # List of all leaf entries that should be on the database
    var leafsLeft = kvpLeafs.mapIt(it.leafTie).toHashSet

    # Provide a (reproducible) peudo-random copy of the leafs list
    let leafVidPairs = db.randomisedLeafs prng
    xCheck leafVidPairs.len == leafsLeft.len

    # Trigger subsequent saving tasks in loop below
    let (saveMod, saveRest, relax) = block:
      if leafVidPairs.len < 17:    (7, 3, false)
      elif leafVidPairs.len < 31: (11, 7, false)
      else:   (leafVidPairs.len div 5, 11, true)

    # === Loop over leafs ===
    for u,lvp in leafVidPairs:
      let
        runID = n + list.len * u
        tailWalkVerify = 7 # + 999
        doSaveBeOk = ((u mod saveMod) == saveRest)
        (leaf, lid) = lvp

      if doSaveBeOk:
        if not tx.saveToBackend(
            chunkedMpt=false, relax=relax, noisy=noisy, runID):
          return

      # Delete leaf
      let rc = db.delete leaf
      xCheckRc rc.error == (0,0)

      # Update list of remaininf leafs
      leafsLeft.excl leaf

      let deletedVtx = tx.db.getVtx lid
      xCheck deletedVtx.isValid == false

      # Walking the database is too slow for large tables. So the hope is that
      # potential errors will not go away and rather pop up later, as well.
      if leafsLeft.len <= tailWalkVerify:
        if u < leafVidPairs.len-1:
          if fwdRevVfyToggle:
            fwdRevVfyToggle = false
            if not db.fwdWalkVerify(leaf.root, leafsLeft, noisy, runID):
              return
          else:
            fwdRevVfyToggle = true
            if not db.revWalkVerify(leaf.root, leafsLeft, noisy, runID):
              return

    when true and false:
      noisy.say "***", "del(9) n=", n, "/", list.len, " nLeafs=", kvpLeafs.len

  true


proc testTxMergeProofAndKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                         # Rocks DB storage directory
    resetDb = false;
    idPfx = "";
    oops: KnownHasherFailure = @[];
      ): bool =
  let
    oopsTab = oops.toTable
  var
    db = AristoDbRef()
    tx = AristoTxRef(nil)
    rootKey: Hash256
    count = 0
  defer:
    db.finish(flush=true)

  for n,w in list:

    # Start new database upon request
    if resetDb or w.root != rootKey or w.proof.len == 0:
      db.innerCleanUp
      db = block:
        # New DB with disabled filter slots management
        if 0 < rdbPath.len:
          let rc = AristoDbRef.init(RdbBackendRef, rdbPath, QidLayoutRef(nil))
          xCheckRc rc.error == 0
          rc.value
        else:
          AristoDbRef.init(MemBackendRef, QidLayoutRef(nil))

      # Start transaction (double frame for testing)
      tx = db.txBegin().value.to(AristoDbRef).txBegin().value
      xCheck tx.isTop()

      # Update root
      rootKey = w.root
      count = 0
    count.inc

    let
      testId = idPfx & "#" & $w.id & "." & $n
      runID = n
      lstLen = list.len
      sTabLen = db.top.sTab.len
      lTabLen = db.top.lTab.len
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie

    var
      proved: tuple[merged: int, dups: int, error: AristoError]
    if 0 < w.proof.len:
      let rc = db.merge(rootKey, VertexID(1))
      xCheckRc rc.error == 0

      proved = db.merge(w.proof, rc.value) # , noisy)

      xCheck proved.error in {AristoError(0),MergeHashKeyCachedAlready}
      xCheck w.proof.len == proved.merged + proved.dups
      xCheck db.top.lTab.len == lTabLen
      xCheck db.top.sTab.len <= proved.merged + sTabLen
      xCheck proved.merged < db.top.pAmk.len

    let
      merged = db.merge leafs

    xCheck db.top.lTab.len == lTabLen + merged.merged
    xCheck merged.merged + merged.dups == leafs.len
    xCheck merged.error in {AristoError(0), MergeLeafPathCachedAlready}

    block:
      let oops = oopsTab.getOrDefault(testId,(0,AristoError(0)))
      if not tx.saveToBackendWithOops(
          chunkedMpt=true, noisy=noisy, debugID=runID, oops):
        return

    when true and false:
      noisy.say "***", "proofs(6) <", n, "/", lstLen-1, ">",
        " groups=", count, " proved=", proved.pp, " merged=", merged.pp
  true


proc testTxSpanMultiInstances*(
    noisy: bool;
    genBase = 42;
      ): bool =
  ## Test multi tx behaviour with span synchronisation
  ##
  let
    db = AristoDbRef.init() # no backend needed
  var
    dx: seq[AristoDbRef]

  var genID = genBase
  proc newPathID(): PathID =
    result = PathID(pfx: genID.u256, length: 64)
    genID.inc
  proc newPayload(): Blob =
    result = @[genID].encode
    genID.inc

  proc show(serial = -42) =
    var s = ""
    if 0 <= serial:
      s &= "n=" & $serial
    s &= "\n   db level=" & $db.level
    s &= " inTxSpan=" & $db.inTxSpan
    s &= " nForked=" & $db.nForked
    s &= " nTxSpan=" & $db.nTxSpan
    s &= "\n    " & db.pp
    for n,w in dx:
      s &= "\n"
      s &= "\n   dx[" & $n & "]"
      s &= " level=" & $w.level
      s &= " inTxSpan=" & $w.inTxSpan
      s &= "\n    " & w.pp
    noisy.say "***", s, "\n"

  # Add some data and first transaction
  block:
    let rc = db.merge(newPathID(), newPayload())
    xCheckRc rc.error == 0
  block:
    let rc = db.checkTop(relax=true)
    xCheckRc rc.error == (0,0)
  xCheck not db.inTxSpan

  # Fork and populate two more instances
  for _ in 1 .. 2:
    block:
      let rc = db.forkTop
      xCheckRc rc.error == 0
      dx.add rc.value
    block:
      let rc = dx[^1].merge(newPathID(), newPayload())
      xCheckRc rc.error == 0
    block:
      let rc = db.checkTop(relax=true)
      xCheckRc rc.error == (0,0)
    xCheck not dx[^1].inTxSpan

  #show(1)

  # Span transaction on a non-centre instance fails but succeeds on centre
  block:
    let rc = dx[0].txBeginSpan
    xCheck rc.isErr
    xCheck rc.error == TxSpanOffCentre
  block:
    let rc = db.txBeginSpan
    xCheckRc rc.error == 0

  # Now all instances have transactions level 1
  xCheck db.level == 1
  xCheck db.inTxSpan
  xCheck db.nForked == dx.len
  xCheck db.nTxSpan == dx.len + 1
  for n in 0 ..< dx.len:
    xCheck dx[n].level == 1
    xCheck dx[n].inTxSpan

  #show(2)

  # Add more data ..
  block:
    let rc = db.merge(newPathID(), newPayload())
    xCheckRc rc.error == 0
  for n in 0 ..< dx.len:
    let rc = dx[n].merge(newPathID(), newPayload())
    xCheckRc rc.error == 0

  #show(3)

  # Span transaction on a non-centre instance fails but succeeds on centre
  block:
    let rc = dx[0].txBeginSpan
    xCheck rc.isErr
    xCheck rc.error == TxSpanOffCentre
  block:
    let rc = db.txBegin
    xCheckRc rc.error == 0

  # Now all instances have transactions level 2
  xCheck db.level == 2
  xCheck db.inTxSpan
  xCheck db.nForked == dx.len
  xCheck db.nTxSpan == dx.len + 1
  for n in 0 ..< dx.len:
    xCheck dx[n].level == 2
    xCheck dx[n].inTxSpan

  #show(4)

  # Fork first transaction from a forked instance
  block:
    let rc = dx[0].txTop.value.parent.forkTx
    xCheckRc rc.error == 0
    dx.add rc.value

  # No change for the other instances
  xCheck db.level == 2
  xCheck db.inTxSpan
  xCheck db.nForked == dx.len
  for n in 0 ..< dx.len - 1:
    xCheck dx[n].level == 2
    xCheck dx[n].inTxSpan

  # This here has changed
  xCheck db.nTxSpan == dx.len
  xCheck not dx[^1].inTxSpan
  xCheck dx[^1].level == 1

  # Add transaction outside tx span
  block:
    let rc = dx[^1].txBegin
    xCheckRc rc.error == 0
  xCheck not dx[^1].inTxSpan
  xCheck dx[^1].level == 2

  # No change for the other instances
  xCheck db.level == 2
  xCheck db.inTxSpan
  xCheck db.nForked == dx.len
  xCheck db.nTxSpan == dx.len
  for n in 0 ..< dx.len - 1:
    xCheck dx[n].level == 2
    xCheck dx[n].inTxSpan

  #show(5)

  # Commit on a non-centre span instance fails but succeeds on centre
  block:
    let rc = dx[0].txTop.value.commit
    xCheck rc.isErr
    xCheck rc.error == TxSpanOffCentre
  block:
    let rc = db.txTop.value.commit
    xCheckRc rc.error == 0
  block:
    let rc = db.check() # full check as commit hashifies
    xCheckRc rc.error == (0,0)
  for n in 0 ..< dx.len - 1:
    let rc = dx[n].check()
    xCheckRc rc.error == (0,0)

  # Verify changes for the span instances
  xCheck db.level == 1
  xCheck db.inTxSpan
  xCheck db.nForked == dx.len
  xCheck db.nTxSpan == dx.len
  for n in 0 ..< dx.len - 1:
    xCheck dx[n].level == 1
    xCheck dx[n].inTxSpan

  # No changes for the instance outside tx span
  xCheck not dx[^1].inTxSpan
  xCheck dx[^1].level == 2

  #show(6)

  # Destroy one instance from the span instances
  block:
    let
      dxTop = dx.pop
      rc = dx[^1].forget
    xCheckRc rc.error == 0
    dx[^1] = dxTop

  # Verify changes for the span instances
  xCheck db.level == 1
  xCheck db.inTxSpan
  xCheck db.nForked == dx.len
  xCheck db.nTxSpan == dx.len
  for n in 0 ..< dx.len - 1:
    xCheck dx[n].level == 1
    xCheck dx[n].inTxSpan

  # No changes for the instance outside tx span
  xCheck not dx[^1].inTxSpan
  xCheck dx[^1].level == 2

  # Finish up span instances
  block:
    let rc = db.txTop.value.collapse(commit = true)
    xCheckRc rc.error == 0
  block:
    let rc = db.check() # full check as commit hashifies
    xCheckRc rc.error == (0,0)
  for n in 0 ..< dx.len - 1:
    let rc = dx[n].check()
    xCheckRc rc.error == (0,0)

  # No span instances anymore
  xCheck db.level == 0
  xCheck not db.inTxSpan
  xCheck db.nForked == dx.len
  xCheck db.nTxSpan == 0
  for n in 0 ..< dx.len - 1:
    xCheck dx[n].level == 0
    xCheck not dx[n].inTxSpan

  #show(7)

  # Clean up
  block:
    let rc = db.forgetOthers()
    xCheckRc rc.error == 0
    dx.setLen(0)
  xCheck db.level == 0
  xCheck not db.inTxSpan
  xCheck db.nForked == 0
  xCheck db.nTxSpan == 0

  #show(8)

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
