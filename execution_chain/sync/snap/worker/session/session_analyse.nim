# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/[tables, typetraits],
  pkg/[chronicles, chronos, eth/common],
  ../[mpt, worker_desc]

logScope:
  topics = "snap sync"

type
  AttType* = enum
    ## Something to pay attantion, to.
    Dangling = 1                                    # w/parent key and node
    Leaf                                            # with key and payload

    ERlpExcept                                      # rlp exception error
    ERlpList                                        # no list with 2 or 17 items
    ENoRoot                                         # dangling root key
    ENoBranch                                       # missing branches
    ENoPivot                                        # no pivot state
    ECancelled                                      # shutdown?
    EGeneric                                        # any other error

  TravNotifyCB* = proc(
    att: AttType, path: NibblesBuf, key, data: seq[byte], depth: int
      ) {.gcsafe, raises: [].}
    ## Closure function used as call back when analysing an MPT. This
    ## function is involved whenever there is something *interesting*
    ## found (e.g. dangling link, leaf node.)

  # ----------------

  WalkTrieGetCB = proc(
    db: MptAsmRef, key: seq[byte]
      ): seq[byte] {.gcsafe, raises: [].}

  WalkStatsRef = ref WalkStatsObj
  WalkStatsObj = object                             # MPT traversal statistics
    accDepth: int                                   # accounts MPT depth max
    nAccDangl: uint                                 # accounts MPT dangling link
    nAccLeaf: uint                                  # accounts visited
    nAccSto: uint                                   # valid storage roots
    nAccCode: uint                                  # valid code hashes

    stoDepth: int                                   # stprage MPT depth max
    nStoDangl: uint                                 # storage MPT dangling link
    nStoLeaf: uint                                  # storage slots visited

    nErr: uint                                      # accumulated error count
    ela: Duration                                   # total time spent analysing
    msgAt: Moment                                   # for logging
    spill: Duration                                 # thred switch elapsed time

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

proc init[T: WalkStack](_: type T, root: seq[byte]): T =
  var st = T(size: 1)                               # initialise first entry
  st.data[0].last = -1                              # base entry (sort of dummy)
  st.data[0].links[0] = (NibblesBuf(),root)         # initialise root link
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

func decodeAccount(pyl: seq[byte]): Opt[Account] =
  try:
    var acc = rlp.decode(pyl, Account)
    return ok(move acc)
  except RlpError:
    discard
  err()

proc findPivot(db: MptAsmRef): Opt[WalkStateData] =
  for state in db.walkStateData():
    if state.error.len == 0 and state.tag == PivotOnTrie:
      return ok state
  err()

template toKey(rlp: Rlp): seq[byte] =
  ## Convert to hask key or node data if it is a list (=> length smaller 32)
  if rlp.isList: @(rlp.rawData) else: rlp.toBytes

template walkTrieTicker(
    ctx: SnapCtxRef;
    napAt: Moment;
    spill: Duration;
    info: static[string];
      ): auto =
  ## Async template, helper template
  ##
  var bodyRc = Opt[void].ok()
  block body:
    let start = Moment.now()
    if napAt < start:
      try:
        await sleepAsync threadSwitchTimeSlot
      except CancelledError as e:
        chronicles.error info & ": Async wait cancelled",
          error=($e.name & "(" & e.msg & ")")
        bodyRc = typeof(bodyRc).err()
        break body
      # Check for scheduler shutdown after thread switch
      if not ctx.daemon:
        chronicles.error info & ": Daemon session terminated"
        bodyRc = typeof(bodyRc).err()
        break body
      let now = Moment.now()
      napAt = now + threadSwitchRunLimit            # next thread switch time
      spill += now - start
      # End  `block body`
  bodyRc

# ------------------------------------------------------------------------------
# Private functions, MPT traversal core function
# ------------------------------------------------------------------------------

template traverseMpt(
    db: MptAsmRef;
    root: seq[byte];                                # root key
    get: WalkTrieGetCB;                             # fetch function
    notify: TravNotifyCB;                           # tell node position
    ctx: SnapCtxRef;                                # not `nil` or no `info`
    info: static[string];                           # unset => ignore `ctx`
      ): auto =
  ## Async template
  ##
  ## Iteratively walk trie, depth first. Returns the time spent when
  ## switching threads
  ##
  var bodyRc = Result[Duration,AttType].err(EGeneric)
  block body:
    var
      stack = WalkStack.init root                   # stack avoids recursion
      spill: Duration                               # time spent somewhere else

    # Helper setting to allow thread switch when enabled
    when 0 < info.len:
      var napAt = Moment.now()+threadSwitchRunLimit # allow thread switch below

    while 0 < stack.len:
      var
        newTop: WalkState                           # stub, new top
        depth: int                                  # info for call backs
        path: NibblesBuf                            # path from stack
        key: seq[byte]                              # key from stack
        node: seq[byte]                             # node from DB

      block hideSomeSettings:
        template inx(): auto = stack.top.last       # top entry field
        template links(): auto = stack.top.links    # ditto
        template parent(): auto = stack.top.parent  # ..

        # Check whether there is a new link available
        inx.inc                                     # set to next item index
        if 15 < inx or links[inx].key.len == 0:     # no more links?
          stack.pop()                               # pop from stack
          continue

        depth = stack.len - 2                       # info for call backs
        path = parent.path & links[inx].pfx         # path from stack
        key = links[inx].key                        # key from stack
        node = get(db, key)                         # node from DB

        if node.len == 0:                           # dangling link?
          if parent.node.len == 0:                  # fail to resolve `root`?
            doAssert key == root
            notify(ENoRoot, NibblesBuf(), root, EmptyBlob, depth)
            bodyRc = typeof(bodyRc).err(ENoRoot)    # => missing root, error
            break body
          notify(Dangling, path, parent.key, parent.node, depth)
          continue

        # Allow thread switch when enabled
        when 0 < info.len:
          walkTrieTicker(ctx, napAt, spill, info).isOkOr:
            notify(ECancelled, path, parent.key, parent.node, depth)
            bodyRc = typeof(bodyRc).err(ECancelled) # => cancel, error
            break body

        # Stub to be completed, below
        newTop.last = -1
        newTop.parent = (path, key, node)
        # End `block hideSomeSettings`

      # Evaluate node and calculate next links
      try:
        var rlp = node.rlpFromBytes()
        case rlp.listLen
        of 2:
          let (isLeaf, pfx) = NibblesBuf.fromHexPrefix rlp.listElem(0).toBytes
          var pyl = rlp.listElem(1)                 # Rlp type, payload or link

          if isLeaf:                                # notify about leaf
            notify(Leaf, path & pfx, key, pyl.read seq[byte], depth+1)
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
            notify(ENoBranch, path, key, node, depth)
          else:
            stack.push newTop

        else:
          notify(ERlpList, path, key, node, depth)

      except RlpError:
        notify(ERlpExcept, path, key, node, depth)

      bodyRc = typeof(bodyRc).ok(spill)
      # End while

  bodyRc                                            # return code

# ------------------------------------------------------------------------------
# Private functions, traversal notifier functions
# ------------------------------------------------------------------------------

proc accountsNotifier(info: static[string]): (TravNotifyCB, WalkStatsRef) =
  let
    stats = WalkStatsRef(msgAt: Moment.now() + threadLogTimeLimit)
    notify = proc(
      att: AttType, path: NibblesBuf, key, data: seq[byte], depth: int) =
        if stats.accDepth < depth:
          stats.accDepth = depth

        case att:
        of Leaf:
          stats.nAccLeaf.inc
          block forAccount:
            let acc = data.decodeAccount().valueOr:
              stats.nErr.inc
              break forAccount
            if acc.storageRoot != EMPTY_ROOT_HASH:
              stats.nAccSto.inc
            if acc.codeHash != EMPTY_CODE_HASH:
              stats.nAccCode.inc

        of Dangling:
          stats.nAccDangl.inc

        else:
          stats.nErr.inc

        if stats.msgAt < Moment.now():
          trace info & ": traversing accounts..", nDangl=stats.nAccDangl,
            nAccount=stats.nAccLeaf, nStorage=stats.nAccSto,
            nCode=stats.nAccCode, nErr=stats.nErr, depthMax=stats.accDepth
          stats.msgAt = Moment.now() + threadLogTimeLimit

  (notify, stats)

# ------------------------------------------------------------------------------
# Private functions, MPT analysers
# ------------------------------------------------------------------------------

template analyseAccountsTrie(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Variant of `analyse()` running on the snap accounts table.
  ##
  var bodyRc = Result[WalkStatsRef,AttType].err(EGeneric)
  block body:
    let
      db = ctx.pool.mptAsm
      pivot = db.findPivot().valueOr:
        debug info & ": accounts MPT traversal pivot missing"
        bodyRc = typeof(bodyRc).err(ENoPivot)       # => missing pivot, error
        break body
      (notify, stats) = accountsNotifier(info)

      start = Moment.now()
      spill = traverseMpt(
        db, @(pivot.root.Hash32.data), getAccTrie, notify, ctx, info).valueOr:
          bodyRc = typeof(bodyRc).err(error)
          break body

    stats.spill = spill
    stats.ela = (Moment.now() - start) - spill
    bodyRc = typeof(bodyRc).ok(stats)               # => ok, statistics

  bodyRc                                            # return code

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template sessionAnalyseTrie*(
    ctx: SnapCtxRef;
    info: static[string];
      ): auto =
  ## Async template
  ##
  ## Traverse (depth first) the accounts MPT and invoke the closure
  ## function argument `notify` when
  ## * a leaf node is found
  ## * a dangling link is found
  ## * an error is encountered
  ##
  var bodyRc = Opt[Duration].err()
  block body:
    debug info & ": start traversing accounts MPT.."

    let stats = ctx.analyseAccountsTrie(info).valueOr:
      debug info & ": failed traversing accounts MPT", `error`=error
      break body

    debug info & ": done traversing accounts MPT", nDangl=stats.nAccDangl,
      nAccount=stats.nAccLeaf, nStorage=stats.nAccSto, nCode=stats.nAccCode,
      nErr=stats.nErr, depthMax=stats.accDepth, ela=stats.ela.toStr,
      spill=stats.spill.toStr

    bodyRc = typeof(bodyRc).ok(stats.ela)

  bodyRc                                            # return code

proc analyseTable*(
    tab: Table[seq[byte],seq[byte]];
    root: Hash32;
    notify: TravNotifyCB;
      ) {.async: (raises: []).} =
  ## Variant of `sessionAnalyseTrie()` for a memory table instead of a kvt
  ## from `MptAsmRef`.
  ##
  ## This function is intended mainly for traversal debugging and testing.
  ##
  proc getFromTable(_: MptAsmRef, k: seq[byte]): seq[byte] =
    tab.withValue(k, val):
      return val
    # @[]
  discard traverseMpt(
    MptAsmRef(nil), @(root.data), getFromTable, notify, nil, "")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
