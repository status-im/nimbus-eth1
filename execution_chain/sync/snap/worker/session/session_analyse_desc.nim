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
  pkg/[chronos, eth/common],
  ../[mpt, worker_desc]

type
  AttType* = enum
    ## Something to pay attantion, to.
    AttDangling = 1                                 # w/parent key and node
    AttLeaf                                         # with key and payload

    ERlpExcept                                      # rlp exception error
    ERlpList                                        # no list with 2 or 17 items
    ENoRoot                                         # dangling root key
    ENoBranch                                       # missing branches
    ENoPivot                                        # no pivot state
    ECancelled                                      # shutdown?
    EGetError                                       # serious database problem?
    EClearError                                     # ..
    EPutError
    EOtherError                                     # any other error

  OnDanglingCB* = proc(key, path: openArray[byte]) {.gcsafe, raises:[].}
    ## Closure function to perform bespoke actions when a dangling link or
    ## a completely missing sub-MPT is found.

  TravNotifyCB* =
      proc(att: AttType, path, key, data: openArray[byte], depth: int
        ) {.gcsafe, raises: [].}
    ## Internal closure function used as call back when analysing an MPT.
    ## This function is involved whenever there is something *interesting*
    ## found (e.g. dangling link, leaf node.)
    ##
    ## Intended for debugging, mainly

  # ----------

  WalkTrieGetCB* = proc(
    db: MptAsmRef, key: openArray[byte]
      ): BlobResult {.gcsafe, raises: [].}

  WalkStats* = tuple                                # MPT traversal statistics
    ## Statistics collector
    nAccDepth: int                                  # accounts MPT depth max
    nAccDangl: uint                                 # accounts MPT dangling link
    nAccLeaf: uint                                  # accounts visited
    nAccSto: uint                                   # valid storage roots
    nAccCode: uint                                  # valid code hashes
    nAccNodes: uint                                 # MPT nodes visited
    nAccErr: uint                                   # accumulated error count

    nStoDepth: int                                  # stprage MPT depth max
    nStoMissing: uint                               # sto MPT completely missing
    nStoDangl: uint                                 # storage MPT dangling link
    nStoLeaf: uint                                  # storage slots visited
    nStoNodes: uint                                 # MPT nodes visited
    nStoErr: uint                                   # accumulated error count
    stoEla: Duration                                # time spent on sto MPT

    nCodeMissing: uint                              # code completely missing

    nNodes: uint                                    # MPT nodes counter
    ela: Duration                                   # total time spent analysing

  TravDescRef* = ref object                         # MPT traversal descriptor
    ctx*: SnapCtxRef                                # snap context
    db*: MptAsmRef                                  # database
    onAccDangl*: OnDanglingCB                       # configurable actions
    onStoDangl*: OnDanglingCB                       # ditto
    onStoMissing*: OnDanglingCB                     # ..
    onCodeMissing*: OnDanglingCB
    msgAt*: Moment                                  # occasional logging
    napAt*: Moment                                  # occasional thread switch
    stats*: WalkStats                               # MPT traversal statistics

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func decodeAccount*(pyl: openArray[byte]): Opt[Account] =
  try:
    var acc = rlp.decode(pyl, Account)
    return ok(move acc)
  except RlpError:
    discard
  err()

proc findPivot*(db: MptAsmRef): Opt[WalkStateData] =
  for state in db.walkStateData():
    if state.error.len == 0 and state.tag == PivotOnTrie:
      return ok state
  err()

template toKey*(rlp: Rlp): seq[byte] =
  ## Convert to hask key or node data if it is a list (=> length smaller 32)
  if rlp.isList: @(rlp.rawData) else: rlp.toBytes

# ------------------------------------------------------------------------------
# Public trie analysis logging helpers
# ------------------------------------------------------------------------------

template occasionalMsg*(
    msgAt: Moment;
    code: untyped;
      ): auto =
  if msgAt < Moment.now():
    code
    msgAt = Moment.now() + threadLogTimeLimit

template traversingStorageMsg*(
    stats: WalkStats;
    info: static[string];
      ): untyped =
  trace info & ": Collecting storage slots..",
    nMissing=stats.nStoMissing, nDangl=stats.nStoDangl, nSlots=stats.nStoLeaf,
    nDepth=stats.nStoDepth, nErr=stats.nStoErr

template traversingCodeMsg*(
    stats: WalkStats;
    info: static[string];
      ): untyped =
  trace info & ": Collecting codes..",
    nMissing=stats.nCodeMissing, nCodes=stats.nAccCode

template traversingAccountsMsg*(
    stats: WalkStats;
    info: static[string];
      ): untyped =
  trace info & ": Collecting accounts..",
    nDangl=stats.nAccDangl, nAccount=stats.nAccLeaf, nDepth=stats.nAccDepth,
    nStorage=stats.nAccSto, nCode=stats.nAccCode, nErr=stats.nAccErr

template startTraversingMsg*(
    info: static[string];
      ): untyped =
  trace info & ": Analysing MPT.."

template allDoneMsg*(
    stats: WalkStats;
    info: static[string];
      ): untyped =
  debug info & ": Done analysing MPT",
    nAccDangl=stats.nAccDangl, nAccount=stats.nAccLeaf,
    nAccNodes=stats.nAccNodes, nAccDepth=stats.nAccDepth,
    accEla=(stats.ela - stats.stoEla).toStr,

    nStorage=stats.nAccSto, nStoSlots=stats.nStoLeaf,
    nStoMissing=stats.nStoMissing, nStoDangl=stats.nStoDangl,
    nStoNodes=stats.nStoNodes, nStoDepth=stats.nStoDepth,
    stoEla=stats.stoEla.toStr,

    nCode=stats.nAccCode, nCodeMissing=stats.nCodeMissing,

    nNodes=stats.nNodes, ela=stats.ela.toStr, nErr=(stats.nAccErr+stats.nStoErr)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
