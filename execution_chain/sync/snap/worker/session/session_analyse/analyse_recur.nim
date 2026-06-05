# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.used.}

## Recursively implemented session analyser
## ========================================
##
## This method does not allow for `async` pseudo-thread switching.
##

{.push raises:[].}

import
  std/tables,
  pkg/[chronicles, chronos, eth/common],
  ../../[helpers, mpt, worker_desc],
  ../session_helpers,
  ./analyse_desc

logScope:
  topics = "snap sync"

type
  WalkTrieRecCB = proc(
    trd: TravDescRef, att: AttType, root: Hash32,
    path, key, data: openArray[byte], depth: int
      ) {.gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Private functions, MPT traversal core function
# ------------------------------------------------------------------------------

proc getAccKvtWrap(
    db: MptAsmRef;
    _: Hash32;
    key: openArray[byte];
      ): BlobResult =
  db.getAccKvt key

proc walkTrieRecImpl(
    trd: TravDescRef,
    base: Hash32;                                   # zero or account path
    root: openArray[byte];                          # current dub-MPT root
    path: NibblesBuf;                               # node path
    key: openArray[byte];                           # node key
    node: openArray[byte];                          # rlp encoded node data
    get: WalkTrieGetCB;                             # fetch function
    notify: WalkTrieRecCB;                          # event notifier
    depth: int;
      ) =
  ## Recursively walk trie, depth first
  ##
  doAssert depth <= 64
  trd.stats.nNodes.inc                              # statistics

  template recurseOrNotify(pfx: NibblesBuf, link: Rlp) =
    block body:
      if link.isList:                                 # no Hash32 but node data
        trd.walkTrieRecImpl(
          base, root, pfx, link.rawData, link.rawData, get, notify, depth+1)
      else:
        let
          newKey = link.toBytes                       # get link
          newNode = trd.db.get(base, newKey).valueOr: # get node from DB
            trd.notify(EGetError, base, EmptyBlob, newKey, EmptyBlob, depth)
            break body
        if newNode.len == 0:
          trd.notify(AttDangling,
            base, pfx.toHexPrefix(false).data(), newKey, EmptyBlob, depth)
        else:
          trd.walkTrieRecImpl(
            base, root, pfx, newKey, newNode, get, notify, depth+1)
  try:
    var rlp = node.rlpFromBytes()
    case rlp.listLen
    of 2:
      let
        (isLeaf, pfx) = NibblesBuf.fromHexPrefix rlp.listElem(0).toBytes
        newPath = path & pfx
      var
        pyl = rlp.listElem(1)                       # Rlp type, payload or link
      if isLeaf:
        trd.notify(AttLeaf,                         # full path => 32 bytes
          base, newPath.getBytes(), key, pyl.read seq[byte], depth)
      else:
        newPath.recurseOrNotify(pyl)
    of 17:
      var n = 0u8
      for w in rlp.items:
        if not w.isEmpty:
          (path & NibblesBuf.nibble(n)).recurseOrNotify(w)
        n.inc
    else:
      trd.notify(ERlpList,
        base, path.toHexPrefix(false).data(), key, node, depth)
  except RlpError:
    trd.notify(ERlpExcept,
      base, path.toHexPrefix(false).data(), key, node, depth)

  discard                                           # visual alignment

proc walkTrieRec(
    trd: TravDescRef;
    base: Hash32;                                   # zero or account path
    root: openArray[byte];                          # state root
    get: WalkTrieGetCB;                             # fetch function
    notify: WalkTrieRecCB;                          # node event notifier
      ): Result[void,AttType] =
  ## Starter
  let node = trd.db.get(base, root).valueOr:
    trd.notify(EGetError, base, EmptyBlob, root, EmptyBlob, 0)
    return err(EGetError)
  if node.len == 0:
    trd.notify(ENoRoot, base, EmptyBlob, root, EmptyBlob, 0)
    return err(ENoRoot)

  trd.walkTrieRecImpl(base, root, EmptyPath, root, node, get, notify, 0)
  return ok()

# ------------------------------------------------------------------------------
# Private functions, traversal notifier functions
# ------------------------------------------------------------------------------

proc stoNotifyRecur(info: static[string]): WalkTrieRecCB =
  return proc(
      trd: TravDescRef;
      att: AttType;
      base: Hash32;
      path: openArray[byte];
      key: openArray[byte];
      data: openArray[byte];
      depth: int;
        ) =
    template stats(): auto = trd.stats

    if stats.nStoDepth < depth:
      stats.nStoDepth = depth
    case att:
    of AttLeaf:
      stats.nStoLeaf.inc
    of AttDangling:
      stats.nStoDangl.inc
      trd.putDanglSto(base, key, path, info)
    of ENoRoot:
      stats.nStoMissing.inc
      trd.putMissSto(base, key, path, info)
    else:
      stats.nStoErr.inc

    occasionalMsg(trd.msgAt):
      traversingStorageMsg(stats, info)

proc accAndStoNotifyRecur(info: static[string]): WalkTrieRecCB =
  return proc(
      trd: TravDescRef;
      att: AttType;
      _: Hash32;
      path: openArray[byte];
      key: openArray[byte];
      payload: openArray[byte];                     # node or payload
      depth: int;
        ) =
    template stats(): auto = trd.stats

    stats.nAccNodes += stats.nNodes                 # collect account stats
    stats.nNodes = 0

    if stats.nAccDepth < depth:
      stats.nAccDepth = depth

    case att:
    of AttLeaf:
      stats.nAccLeaf.inc

      block forAccount:
        let acc = payload.decodeAccount().valueOr:
          stats.nAccErr.inc
          break forAccount

        if acc.storageRoot != EMPTY_ROOT_HASH:
          stats.nAccSto.inc

          # Analyse MPT for storage slots
          let
            start = Moment.now()
            notify = stoNotifyRecur info
            base = Hash32.fromBytes path

          trd.walkTrieRec(base, acc.storageRoot.data, getStoKvt, notify).isOkOr:
            if error != ENoRoot:
              debug info & ": Failed traversing storage slots",
                root=acc.storageRoot.toStr, nErr=stats.nStoErr, `error`=error

          stats.nStoNodes += stats.nNodes           # collect storage stats
          stats.nNodes = 0
          stats.stoEla += (Moment.now() - start)

        if acc.codeHash != EMPTY_CODE_HASH:
          stats.nAccCode.inc

          # Check whether the code has an entry on the codes list
          block checkCodeHash:
            let rc = trd.db.hasCodeKvt(acc.codeHash)
            if rc.isErr:
              debug info & ": Failed accessing byte code",
                root=acc.codeHash.toStr, nErr=stats.nStoErr, error=rc.error
            elif rc.value:
              break checkCodeHash
            stats.nCodeMissing.inc                  # (key,path) of account data
            trd.putMissCode(key, path, info)

          occasionalMsg(trd.msgAt):
            traversingCodeMsg(stats, info)

    of AttDangling:
      stats.nAccDangl.inc
      trd.putDanglAcc(key, path, info)

    else:
      stats.nAccErr.inc

    occasionalMsg(trd.msgAt):
      traversingAccountsMsg(stats, info)

proc accOnlyNotifyRecur(info: static[string]): WalkTrieRecCB =
  return proc(
      trd: TravDescRef;
      att: AttType;
      _: Hash32;
      path: openArray[byte];
      key: openArray[byte];
      payload: openArray[byte];                     # node or payload
      depth: int;
        ) =
    template stats(): auto = trd.stats

    stats.nAccNodes += stats.nNodes                 # collect account stats
    stats.nNodes = 0

    if stats.nAccDepth < depth:
      stats.nAccDepth = depth

    case att:
    of AttLeaf:
      stats.nAccLeaf.inc

      block forAccount:
        let acc = payload.decodeAccount().valueOr:
          stats.nAccErr.inc
          break forAccount

        var treatAccAsDangling = false
        if acc.storageRoot != EMPTY_ROOT_HASH:
          stats.nAccSto.inc

          # Check whether the storage root has an entry on the database
          block checkStoRoot:
            let
              base = Hash32.fromBytes path
              rc = trd.db.hasStoKvt(base, acc.storageRoot.data)
            if rc.isErr:
              debug info & ": Failed accessing storage root",
                root=acc.storageRoot.toStr, nErr=stats.nStoErr, error=rc.error
            elif rc.value:
              break checkStoRoot
            treatAccAsDangling = true
            stats.nStoMissing.inc

        if acc.codeHash != EMPTY_CODE_HASH:
          stats.nAccCode.inc

          # Check whether the code has an entry on the codes list
          block checkCodeHash:
            let rc = trd.db.hasCodeKvt(acc.codeHash)
            if rc.isErr:
              debug info & ": Failed accessing byte code",
                root=acc.codeHash.toStr, nErr=stats.nStoErr, error=rc.error
            elif rc.value:
              break checkCodeHash
            stats.nCodeMissing.inc
            treatAccAsDangling = true

          occasionalMsg(trd.msgAt):
            traversingCodeMsg(stats, info)

        if treatAccAsDangling:                      # count as dangling leaf
          trd.putDanglAcc(key, path, info)
          stats.nAccDangl.inc

    of AttDangling:
      stats.nAccDangl.inc
      trd.putDanglAcc(key, path, info)

    else:
      stats.nAccErr.inc

    occasionalMsg(trd.msgAt):
      traversingAccountsMsg(stats, info)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc sessionAnalyseTrieRecur*(
    ctx: SnapCtxRef;
    accAndStoOk: static[bool];                      # FIXME -- will go away
    info: static[string];
      ): Result[WalkStats,AttType]
      {.deprecated: "Use sessionAnalyseTrie()".} =
  ## Async template (but not running async)
  ##
  ## Traverse (depth first) an MPT and store missing or dangling node links
  ## on the dangling links KVT tables.
  ##
  ## Testing/debugging only (for the moment.)
  ##
  let
    trd = TravDescRef(
      ctx:   ctx,
      db:    ctx.pool.mptAsm,
      msgAt: Moment.now() + threadLogTimeLimit)

    pivot = trd.db.findPivot().valueOr:
      debug info & ": MPT analysis failed, pivot missing"
      return err(ENoPivot)                          # => missing pivot, error

  template stats(): auto = trd.stats

  trace info & ": Clearing dangling links caches"
  trd.clearDanglAcc(info).isOkOr:
    return err(EClearError)

  when accAndStoOk:                                 # FIXME -- will go away
    trd.clearDanglSto(info).isOkOr:
      return err(EClearError)
    trd.clearDanglCode(info).isOkOr:
      return err(EClearError)

    let start = Moment.now()
    startTraversingMsg(info)
    trd.walkTrieRec(
      zeroHash32, pivot.root.Hash32.data, getAccKvtWrap,
      accAndStoNotifyRecur info).isOkOr:
        debug info & ": Failed analysing MPT", `error`=error
        return err(error)
  else:                                             # FIXME -- will go away
    let start = Moment.now()                        # FIXME -- will go away
    startTraversingMsg(info)                        # FIXME -- will go away
    trd.walkTrieRec(                                # FIXME -- will go away
      zeroHash32, pivot.root.Hash32.data, getAccKvtWrap,
      accOnlyNotifyRecur info).isOkOr:              # FIXME -- will go away
        debug info & ": Failed analysing MPT", `error`=error
        return err(error)                           # FIXME -- will go away

  if 0 < trd.cacheErr:
    return err(EPutError)

  stats.nAccNodes += stats.nNodes
  stats.nNodes = stats.nAccNodes + stats.nStoNodes
  stats.ela = Moment.now() - start
  allDoneMsg(stats, info)

  ok(stats)                                         # => ok, statistics

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
