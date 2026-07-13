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
  pkg/[chronicles, chronos, eth/common, stew/interval_set],
  ../../[helpers, mpt, worker_desc],
  ../[session_clear, session_helpers],
  ./analyse_desc

logScope:
  topics = "snap sync"

type
  WalkTrieRecCB = proc(
    trd: TravDescRef, att: AttType, base: Hash32,
    path: NibblesBuf, data: openArray[byte], depth: int
      ) {.gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Private functions, MPT traversal core function
# ------------------------------------------------------------------------------

proc getAccPartMptWrap(
    db: CacheDbRef;
    _: Hash32;
    key: openArray[byte];
      ): BlobResult =
  db.getAccPartMpt key

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
            trd.notify(EGetError, base, EmptyPath, EmptyBlob, depth)
            break body
        if newNode.len == 0:
          trd.notify(AttDangling, base, pfx, EmptyBlob, depth)
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
      if isLeaf:                                    # full path => 32 bytes
        trd.notify(AttLeaf, base, newPath, pyl.read seq[byte], depth)
      else:
        newPath.recurseOrNotify(pyl)
    of 17:
      var n = 0u8
      for w in rlp.items:
        if not w.isEmpty:
          (path & NibblesBuf.nibble(n)).recurseOrNotify(w)
        n.inc
    else:
      trd.notify(ERlpList, base, path, node, depth)
  except RlpError:
    trd.notify(ERlpExcept, base, path, node, depth)

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
    trd.notify(EGetError, base, EmptyPath, EmptyBlob, 0)
    return err(EGetError)
  if node.len == 0:
    trd.notify(ENoRoot, base, EmptyPath, EmptyBlob, 0)
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
      accPath: Hash32;
      stoPath: NibblesBuf;
      slotData: openArray[byte];                    # payload only
       depth: int;
        ) =
    template stats(): auto = trd.stats

    if stats.nStoDepth < depth:
      stats.nStoDepth = depth
    case att:
    of AttLeaf:
      stats.nStoLeaf.inc
      trd.putFlatSlot(
        accPath, Hash32.fromBytes stoPath.getBytes(), slotData, info)
    of AttDangling:
      stats.nStoDangl.inc
      discard trd.ranges.merge ItemKeyRange.fromNibbles stoPath
    of ENoRoot:
      stats.nStoMissing.inc
      discard trd.ranges.merge ItemKeyRange.fromNibbles stoPath
    else:
      stats.nStoErr.inc

    occasionalMsg(trd.msgAt):
      traversingStorageMsg(stats, info)

proc accAndStoNotifyRecur(info: static[string]): WalkTrieRecCB =
  return proc(
      trd: TravDescRef;
      att: AttType;
      root: Hash32;
      accPath: NibblesBuf;
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
      let base = Hash32.fromBytes accPath.getBytes()
      trd.putFlatAcc(base, payload, info)           # flat accounts table

      block forAccount:
        let acc = payload.decodeAccount(info).valueOr:
          stats.nAccErr.inc
          break forAccount

        if acc.storageRoot != EMPTY_ROOT_HASH:
          stats.nAccSto.inc

          # Analyse MPT for storage slots
          let
            start = Moment.now()
            notify = stoNotifyRecur info

          # Start with new set of sub-ranges
          let stash = trd.ranges
          trd.ranges = ItemKeyRangeSet.init()

          trd.walkTrieRec(
                  base, acc.storageRoot.data, getStoPartMpt, notify).isOkOr:
            if error != ENoRoot:
              debug info & ": Failed traversing storage slots",
                root=acc.storageRoot.toStr, nErr=stats.nStoErr, `error`=error

          # Save sub-ranges and re-install accout ranges
          if 0 < trd.ranges.chunks:
            trd.putStoMissingIntv(base, trd.ranges, info)
          trd.ranges = stash

          stats.nStoNodes += stats.nNodes           # collect storage stats
          stats.nNodes = 0
          stats.stoEla += (Moment.now() - start)

        if acc.codeHash != EMPTY_CODE_HASH:
          stats.nAccCode.inc

          block handleCode:
            # Check whether the code has an entry on the database
            let code = trd.db.getCodePartMpt(acc.codeHash).valueOr:
              debug info & ": Failed accessing byte code",
                root=acc.codeHash.toStr, nErr=stats.nStoErr, `error`=error
              trd.cacheErr.inc
              stats.nCodeMissing.inc
              break handleCode

            if 0 < code.len:
              trd.putFlatCode(base, code, info)     # contract codes table
            else:
              stats.nCodeMissing.inc
              trd.putMissingBlob(base, info)        # missing contracts table

    of AttDangling:
      stats.nAccDangl.inc
      discard trd.ranges.merge ItemKeyRange.fromNibbles accPath

    else:
      stats.nAccErr.inc

    occasionalMsg(trd.msgAt):
      traversingAccountsMsg(stats, info)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc sessionAnalyseTrieRecur*(
    ctx: SnapCtxRef;
    info: static[string];
      ): Result[WalkStats,AttType] =
  ## Async template (but not running async)
  ##
  ## Traverse (depth first) an MPT and store missing or dangling node links
  ## on the dangling links KVT tables.
  ##
  ## Testing/debugging only (for the moment.)
  ##
  let
    trd = TravDescRef(
      ctx:    ctx,
      db:     ctx.pool.cacheDB,
      ranges: ItemKeyRangeSet.init(),
      msgAt:  Moment.now() + threadLogTimeLimit)

    pivot = ctx.pool.pivot.valueOr:
      debug info & ": MPT analysis failed, pivot missing"
      return err(ENoPivot)

  template stats(): auto = trd.stats
  startTraversingMsg(info)

  trace info & ": Clearing flat leaf record tables"
  ctx.sessionFlatTabsClear(info).isOkOr:
    return err(EClearError)

  let start = Moment.now()
  trace info & ": Analysing partion MPTs.."
  trd.walkTrieRec(
    zeroHash32, pivot.Hash32.data, getAccPartMptWrap,
    accAndStoNotifyRecur info).isOkOr:
      debug info & ": Failed analysing MPT", `error`=error
      return err(error)

  # Alsways store even without ranges, so the state root gets registered
  trd.putAccMissingIntv(pivot, trd.ranges, info)

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
