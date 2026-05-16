# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Recursively implemented session analyser
## ========================================
##
## This method does not allow for `async` pseudo-thread switching.
##

{.push raises:[].}

import
  std/tables,
  pkg/[chronicles, chronos, eth/common],
  ../[mpt, worker_desc],
  ./session_analyse_desc

logScope:
  topics = "snap sync"

type
  WalkTrieRecCB = proc(
    trd: TravDescRef, att: AttType,
    path: NibblesBuf, key, data: seq[byte], depth: int
      ) {.gcsafe, raises: [].}

# ------------------------------------------------------------------------------
# Private functions, MPT traversal core function
# ------------------------------------------------------------------------------

proc walkTrieRecImpl(
    trd: TravDescRef,
    path: NibblesBuf;                               # node path
    key: seq[byte];                                 # node key
    node: seq[byte];                                # rlp encoded node data
    get: WalkTrieGetCB;                             # fetch function
    notify: WalkTrieRecCB;                          # event notifier
    depth: int;
      ) =
  ## Recursively walk trie, depth first
  ##
  doAssert depth <= 64
  trd.stats.nNodes.inc                              # statistics

  template recurseOrNotify(pfx: NibblesBuf, link: Rlp) =
    if link.isList:                                 # no Hash32 but node data
      let data = @(link.rawData)
      trd.walkTrieRecImpl(pfx, data, data, get, notify, depth+1)
    else:
      let
        newKey = link.toBytes                       # get link
        newNode = trd.db.get newKey                 # get node from DB
      if newNode.len == 0:
        trd.notify(AttDangling, pfx, newKey, EmptyBlob, depth)
      else:
        trd.walkTrieRecImpl(pfx, newKey, newNode, get, notify, depth+1)

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
        trd.notify(AttLeaf, newPath, key, pyl.read seq[byte], depth)
      else:
        newPath.recurseOrNotify(pyl)
    of 17:
      var n = 0u8
      for w in rlp.items:
        if not w.isEmpty:
          (path & NibblesBuf.nibble(n)).recurseOrNotify(w)
        n.inc
    else:
      trd.notify(ERlpList, path, key, node, depth)
  except RlpError:
    trd.notify(ERlpExcept, path, key, node, depth)

  discard                                           # visual alignment

proc walkTrieRec(
    trd: TravDescRef;
    root: Hash32;                                   # root key
    get: WalkTrieGetCB;                             # fetch function
    notify: WalkTrieRecCB;                          # node event notifier
      ): Result[void,AttType] =
  ## Starter
  let
    root = @(root.data)
    node = trd.db.get(root)
  if node.len == 0:
    trd.notify(ENoRoot, NibblesBuf(), root, node, 0)
    return err(ENoRoot)

  trd.walkTrieRecImpl(EmptyPath, root, node, get, notify, 0)
  return ok()

# ------------------------------------------------------------------------------
# Private functions, traversal notifier functions
# ------------------------------------------------------------------------------

proc stoNotifyRecur(info: static[string]): WalkTrieRecCB =
  return proc(
      trd: TravDescRef;
      att: AttType;
      path: NibblesBuf;
      key: seq[byte];
      data: seq[byte];
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
    of ENoRoot:
      stats.nStoMissing.inc
    else:
      stats.nStoErr.inc

    occasionalMsg(trd.msgAt):
      traversingStorageMsg(stats, info)

proc accNotifyRecur(info: static[string]): WalkTrieRecCB =
  return proc(
      trd: TravDescRef;
      att: AttType;
      path: NibblesBuf;
      key: seq[byte];
      data: seq[byte];
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
        let acc = data.decodeAccount().valueOr:
          stats.nAccErr.inc
          break forAccount

        if acc.storageRoot != EMPTY_ROOT_HASH:
          stats.nAccSto.inc

          # Analyse MPT for storage slots
          let
            start = Moment.now()
            notify = stoNotifyRecur info

          trd.walkTrieRec(acc.storageRoot, getStoTrie, notify).isOkOr:
            if error != ENoRoot:
              debug info & ": Failed traversing storage slots",
                root=acc.storageRoot.toStr, nErr=stats.nStoErr, `error`=error

          stats.nStoNodes += stats.nNodes           # collect storage stats
          stats.nNodes = 0
          stats.stoEla += (Moment.now() - start)

        if acc.codeHash != EMPTY_CODE_HASH:
          stats.nAccCode.inc

          # Check whether the code has an entry on the codes list
          if trd.db.getCodeList(acc.codeHash).len == 0:
            stats.nCodeMissing.inc

          occasionalMsg(trd.msgAt):
            traversingCodeMsg(stats, info)

    of AttDangling:
      stats.nAccDangl.inc

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
      ): Opt[Duration]
      {.deprecated: "Use sessionAnalyseTrie()".} =
  ## Async template (but not running async)
  ##
  ## Testing/debugging only
  ##
  let
    start = Moment.now()
    trd = TravDescRef(
      ctx:   ctx,
      db:    ctx.pool.mptAsm,
      msgAt: start + threadLogTimeLimit)

    pivot = trd.db.findPivot().valueOr:
      debug info & ": MPT analysis failed, pivot missing"
      return err()                                  # => missing pivot, error

    root = pivot.root.Hash32
    notify = accNotifyRecur info

  template stats(): auto = trd.stats
  debug info & ": Start recursively analysing MPT"

  trd.walkTrieRec(root, getAccTrie, notify).isOkOr:
    debug info & ": Failed analysing MPT", `error`=error
    return err()                                    # => missing root node

  stats.nAccNodes += stats.nNodes
  stats.nNodes = stats.nAccNodes + stats.nStoNodes
  stats.ela = Moment.now() - start
  allDoneMsg(stats, info)

  ok(stats.ela)                                     # => ok, statistics

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
