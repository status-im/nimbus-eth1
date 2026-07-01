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

## Non-recursively implemented session analyser
## ============================================
##
## This method keeps the system responsive while running by allowing
## `async` pseudo-thread switching.
##

{.push raises:[].}

import
  std/tables,
  pkg/[chronicles, chronos, eth/common],
  ../../[helpers, mpt, worker_desc],
  ../session_helpers,
  ./analyse_desc

export
  AttType

logScope:
  topics = "snap sync"

const
  AllowTreadSwitch = true
    ## Set `true` for allowing thread switch in `traverseMpt()` node walker.
    ##
    ## Note: This setting is temporary and will go away.

type
  WalkParent = tuple
    path: NibblesBuf                                # parent path
    key: seq[byte]                                  # parent key
    node: seq[byte]                                 # parent node

  WalkLink = tuple                                  # extension or branch link
    pfx: NibblesBuf                                 # from nibble or ext-pfx
    key: seq[byte]                                  # link key

  WalkState = object                                # MPT traversal state
    links: array[16,WalkLink]                       # branches for this level
    last: int                                       # last entry index, or -1
    parent: WalkParent

  WalkStack = object
    ## Stack for MPT traveral states, avoids GC management for `seq[]`
    data: array[1 + high(NibblesBuf), WalkState]
    size: uint

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc init[T: WalkStack](_: type T, root: openArray[byte]): T =
  var st = T(size: 1)                               # initialise first entry
  st.data[0].last = -1                              # base entry (sort of dummy)
  st.data[0].links[0] = (NibblesBuf(),@root)        # initialise root link
  st

template len(st: WalkStack): auto =
  st.size.int

template top(st: WalkStack): auto =
  ## Argument stack `st` must have positive size
  doAssert 0 < st.size
  st.data[st.size - 1]

template pop(st: WalkStack) =
  ## Argument stack `st` must have positive size
  doAssert 0 < st.size
  st.size.dec

template push(st: WalkStack, item: WalkState) =
  ## Argument stack `st` must have enough space on top
  doAssert st.size < st.data.len.uint
  st.data[st.size] = item
  st.size.inc

# ------------------

template runErrand(
    trd: TravDescRef;
    info: static[string];
    code: untyped;
      ): auto =
  ## Async template, helper template
  ##
  var bodyRc = Opt[void].ok()
  block body:
    let start = Moment.now()

    if trd.msgAt < start:
      code
      trd.msgAt = Moment.now() + threadLogTimeLimit

    when AllowTreadSwitch:
      if trd.napAt < start:
        try:
          await sleepAsync ZeroDuration
        except CancelledError as e:
          chronicles.error info & ": Async wait cancelled",
            error=($e.name & "(" & e.msg & ")")
          bodyRc = typeof(bodyRc).err()
          break body

        # Check for scheduler shutdown after thread switch
        if not trd.ctx.daemon:
          chronicles.error info & ": Daemon session terminated"
          bodyRc = typeof(bodyRc).err()
          break body
        # Next thread switch time
        trd.napAt = Moment.now() + threadSwitchRunLimit

    # End  `block body`

  bodyRc

# ------------------------------------------------------------------------------
# Private functions, MPT traversal core function
# ------------------------------------------------------------------------------

template getAccKvtWrap(
    db: MptAsmRef;
    _: Hash32;
    key: openArray[byte];
      ): BlobResult =
  ## Ignore state root for `get()` on accounts KVT
  db.getAccKvt key

template traverseMpt(
    trd: TravDescRef;                               # traversal descriptor
    base: Hash32;                                   # zero or account path
    root: openArray[byte];                          # root key
    get: untyped;                                   # fetch function
    notify: untyped;                                # tell node position
    info: static[string];                           # unset => no thread switch
    code: untyped;                                  # e.g. logging
      ): auto =
  ## Async template
  ##
  ## Iteratively walk trie, depth first.
  ##
  var bodyRc = Result[void,AttType].err(EOtherError)
  block body:
    var stack = WalkStack.init root                 # stack avoids recursion

    while 0 < stack.len:
      var
        newTop: WalkState                           # stub, new top
        depth: int                                  # info for call backs
        path: NibblesBuf                            # path from stack
        key: seq[byte]                              # key from stack
        node: seq[byte]                             # node from DB

      block hideSomeSettings:
        template topInx(): auto = stack.top.last    # top entry field
        template topLinks(): auto = stack.top.links # ditto
        template topParent(): auto = stack.top.parent

        # Check whether there is a new link available
        topInx.inc                                  # set to next item index
        if 15 < topInx or
           topLinks[topInx].key.len == 0:           # no more links?
          stack.pop()                               # pop from stack
          continue

        depth = stack.len - 2                       # info for call backs
        path = topParent.path & topLinks[topInx].pfx # path from stack
        key = topLinks[topInx].key                  # key from stack
        node = get(trd.db, base, key).valueOr:      # node from DB
          notify(EGetError, trd, base, EmptyBlob, key, EmptyBlob, depth, info)
          continue

        if node.len == 0:                           # dangling link?
          if topParent.node.len == 0:               # fail to resolve `root`?
            doAssert key == @root
            notify(ENoRoot, trd, base, EmptyBlob, key, EmptyBlob, depth, info)
            bodyRc = typeof(bodyRc).err(ENoRoot)    # => missing root, error
            break body
          notify(AttDangling, trd,
            base, path.toHexPrefix(false).data(), key, EmptyBlob, depth, info)
          continue

        # Allow thread switch when enabled
        when 0 < info.len:
          runErrand(trd, info, code).isOkOr:
            notify(ECancelled, trd,
              base, path.toHexPrefix(false).data(), key, node, depth, info)
            bodyRc = typeof(bodyRc).err(ECancelled) # => cancel, error
            break body

        # Stub to be completed, below
        newTop.last = -1
        newTop.parent = (path, key, node)
        trd.stats.nNodes.inc                        # statistics collector
        # End `block hideSomeSettings`

      # Evaluate node and calculate next links
      try:
        var rlp = node.rlpFromBytes()
        case rlp.listLen
        of 2:
          let (isLeaf, pfx) = NibblesBuf.fromHexPrefix rlp.listElem(0).toBytes
          var pyl = rlp.listElem(1)                 # Rlp type, payload or link

          if isLeaf:                                # notify about leaf
            let data = pyl.read seq[byte]
            notify(AttLeaf, trd,
              base, (path & pfx).getBytes(), key, data, depth+1, info)
            continue

          # Initialse `link[]` data on `newTop` and push on stack
          newTop.links[0] = (pfx, pyl.toKey)
          stack.push newTop

        of 17:
          # Initialse `link[]` data on `newTop`
          var (nIibble, nLnk) = (0u8, 0)
          for w in rlp.items:
            if not w.isEmpty:
              newTop.links[nLnk] = (NibblesBuf.nibble nIibble, w.toKey)
              nLnk.inc
            nIibble.inc

          # Push on stack (or error)
          if nLnk == 0:
            notify(ENoBranch, trd,
              base, path.toHexPrefix(false).data(), key, node, depth, info)
          else:
            stack.push newTop

        else:
          notify(ERlpList, trd,
            base, path.toHexPrefix(false).data(), key, node, depth, info)

      except RlpError:
        notify(ERlpExcept, trd,
          base, path.toHexPrefix(false).data(), key, node, depth, info)
      # End `while()`

    bodyRc = typeof(bodyRc).ok()

  bodyRc                                            # return code

# ------------------------------------------------------------------------------
# Private functions, traversal notifier functions
# ------------------------------------------------------------------------------

template stoNotify(
    att: static[AttType];
    trd: TravDescRef;
    base: Hash32;
    path: openArray[byte];
    key: openArray[byte];
    data: openArray[byte];
    depth: int;
    info: static[string];
      ) =
  block body:
    template stats(): auto = trd.stats

    if stats.nStoDepth < depth:
      stats.nStoDepth = depth

    when att == AttLeaf:
      stats.nStoLeaf.inc

    elif att == AttDangling:
      stats.nStoDangl.inc
      trd.putDanglSto(base, key, path, info)

      occasionalMsg(trd.msgAt):
        traversingCodeMsg(stats, info)

    elif att == ENoRoot:
      stats.nStoMissing.inc
      trd.putMissSto(base, key, path, info)

    else:
      stats.nStoErr.inc

template accAndStoNotify(
    att: static[AttType];
    trd: TravDescRef;
    _: Hash32;
    path: openArray[byte];
    key: openArray[byte];
    payload: openArray[byte];                       # node or payload
    depth: int;
    info: static[string];
      ) =
  block body:
    template stats(): auto = trd.stats

    stats.nAccNodes += stats.nNodes                 # collect account stats
    stats.nNodes = 0

    if stats.nAccDepth < depth:
      stats.nAccDepth = depth

    when att == AttLeaf:
      stats.nAccLeaf.inc

      let acc = payload.decodeAccount().valueOr:
        stats.nAccErr.inc
        break body

      if acc.storageRoot != EMPTY_ROOT_HASH:
        stats.nAccSto.inc

        # Analyse MPT for storage slots
        let
          start = Moment.now()
          base = Hash32.fromBytes path
          rc = traverseMpt(
            trd, base, acc.storageRoot.data, getStoKvt, stoNotify, info):
              traversingStorageMsg(stats, info)   # keep alive message

        if rc.isErr and rc.error != ENoRoot:
          debug info & ": Failed traversing storage slots",
            root=acc.storageRoot.toStr, nErr=stats.nStoErr, `error`=rc.error

        stats.nStoNodes += stats.nNodes           # collect storage stats
        stats.nNodes = 0
        stats.stoEla += (Moment.now() - start)

      if acc.codeHash != EMPTY_CODE_HASH:
        stats.nAccCode.inc

        # Check whether the code has an entry on the database
        block checkCodeHash:
          let rc = trd.db.hasCodeKvt(acc.codeHash)
          if rc.isErr:
            debug info & ": Failed accessing byte code",
              root=acc.codeHash.toStr, nErr=stats.nStoErr, error=rc.error
          elif rc.value:
            break checkCodeHash
          stats.nCodeMissing.inc
          trd.putMissCode(key, path, info)          # (key,path) of account data

      occasionalMsg(trd.msgAt):
        traversingCodeMsg(stats, info)

    elif att == AttDangling:
      stats.nAccDangl.inc
      trd.putDanglAcc(key, path, info)

      occasionalMsg(trd.msgAt):
        traversingCodeMsg(stats, info)

    else:
      stats.nAccErr.inc

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionAnalyseTrieIter*(cty: SnapCtxRef, info: static[string]): auto =
  ## Async template
  ##
  ## Traverse (depth first) an MPT and store missing or dangling node links
  ## on the dangling links KVT tables.
  ##
  var bodyRc = Result[WalkStats,AttType].err(EOtherError)
  block body:
    let
      trd = TravDescRef(
        ctx:   cty,
        db:    cty.pool.mptAsm,
        msgAt: Moment.now() + threadLogTimeLimit,
        napAt: Moment.now() + threadSwitchRunLimit)

      pivot = ctx.pool.pivot.valueOr:
        debug info & ": MPT analysis failed, pivot missing"
        bodyRc = typeof(bodyRc).err(ENoPivot)
        break body

    template stats(): auto = trd.stats

    let start = Moment.now()
    startTraversingMsg(info)

    ctx.clearDanglTables(info).isOkOr:
      bodyRc = typeof(bodyRc).err(EClearError)
      break body

    let rc = traverseMpt(
      trd, zeroHash32, pivot.Hash32.data,
      getAccKvtWrap, accAndStoNotify, info):
        traversingAccountsMsg(stats, info)

    if 0 < trd.cacheErr:
      bodyRc = typeof(bodyRc).err(EPutError)
      break body

    if rc.isErr:
      debug info & ": Failed analysing MPT", `error`=rc.error
      bodyRc = typeof(bodyRc).err(rc.error)
      break body
    
    stats.nAccNodes += stats.nNodes
    stats.nNodes = stats.nAccNodes + stats.nStoNodes
    stats.ela = (Moment.now() - start)
    allDoneMsg(stats, info)

    bodyRc = typeof(bodyRc).ok(stats)               # done, ok
    # End `block body`

  bodyRc                                            # return code

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
