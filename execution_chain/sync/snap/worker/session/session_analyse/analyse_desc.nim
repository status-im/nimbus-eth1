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
  pkg/[chronicles, chronos, eth/common, eth/trie/nibbles],
  pkg/stew/[byteutils, interval_set],
  ../../[mpt, helpers, state_db, worker_desc]

logScope:
  topics = "snap sync"

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
    EAristoError                                    # incomplete import?
    EPartialMpt
    EOtherError                                     # any other error

  OnDanglingCB* = proc(
      base: Hash32; key, path: openArray[byte]) {.gcsafe, raises:[].}
    ## Closure function to perform bespoke actions when a dangling link or
    ## a completely missing sub-MPT is found.

  TravNotifyCB* = proc(
      att: AttType, base: Hash32, path: NibblesBuf, key, data: openArray[byte],
      depth: int) {.gcsafe, raises: [].}
    ## Internal closure function used as call back when analysing an MPT.
    ## This function is involved whenever there is something *interesting*
    ## found (e.g. dangling link, leaf node.)
    ##
    ## Intended for debugging, mainly

  # ----------

  WalkTrieGetCB* = proc(
    db: CacheDbRef, base: Hash32, key: openArray[byte]
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
    db*: CacheDbRef                                 # database
    ranges*: ItemKeyRangeSet                        # derived from dangl. paths
    msgAt*: Moment                                  # occasional logging
    napAt*: Moment                                  # occasional thread switch
    stats*: WalkStats                               # MPT traversal statistics
    cacheErr*: uint                                 # persistent cache errors

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

template toKey*(rlp: Rlp): seq[byte] =
  ## Convert to hask key or node data if it is a list (=> length smaller 32)
  if rlp.isList: @(rlp.rawData) else: rlp.toBytes

proc nMissAccRanges*(trd: TravDescRef, info: static[string]): (UInt256,int) =
  let
    maybe = trd.db.getAccMissingIntv().valueOr:
      error info & ": Error retrieving account ranges", `error`=error
      return (0.u256,-1)
    (_,rng) = maybe.valueOr:
      return (0.u256,0)
  (rng.total(),rng.chunks())

proc putAccMissingIntv*(
    trd: TravDescRef;
    stateRoot: StateRoot;
    ranges: ItemKeyRangeSet;
    info: static[string];
      ) =
  trd.db.putAccMissingIntv(stateRoot, ranges).isOkOr:
    error info & ": Error caching storage account ranges",
      stateRoot=stateRoot.toStr, ranges=ranges.total.per256.pcStr, `error`=error
    trd.cacheErr.inc

proc putStoMissingIntv*(
    trd: TravDescRef;
    accPath: Hash32;
    ranges: ItemKeyRangeSet;
    info: static[string];
      ) =
  trd.db.putStoMissingIntv(accPath, ranges).isOkOr:
    error info & ": Error caching missing storage slot ranges",
      accPath=accPath.toStr, ranges=ranges.total.per256.pcStr, `error`=error
    trd.cacheErr.inc

proc putMissingBlob*(
    trd: TravDescRef;
    accPath: Hash32;
    info: static[string];
      ) =
  trd.db.putMissingBlob(accPath).isOkOr:
    error info & ": Error caching missing contract closde",
      accPath=accPath.toStr, `error`=error
    trd.cacheErr.inc


proc putFlatAcc*(
    trd: TravDescRef;
    accPath: Hash32;
    payload: openArray[byte];
    info: static[string];
      ) =
  trd.db.putFlatAcc(accPath, payload).isOkOr:
    error info & ": Error caching account data",
      accPath=accPath.toStr, payload=payload.toHex, `error`=error
    trd.cacheErr.inc

proc putFlatSlot*(
    trd: TravDescRef;
    accPath: Hash32;
    slotKey: Hash32;
    payload: openArray[byte];
    info: static[string];
      ) =
  trd.db.putFlatSlot(accPath, slotKey, payload).isOkOr:
    error info & ": Error caching flat storage slot data",
      accPath=accPath.toStr, slotKey=slotKey.toStr, payload=payload.toHex,
      `error`=error
    trd.cacheErr.inc

proc putFlatCode*(
    trd: TravDescRef;
    accPath: Hash32;
    data: openArray[byte];
    info: static[string];
      ) =
  trd.db.putFlatCode(accPath, data).isOkOr:
    error info & ": Error caching contract code data",
      accPath=accPath.toStr, codeData=data.toHex, `error`=error
    trd.cacheErr.inc

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
    nAccDangl=stats.nAccDangl, nAccounts=stats.nAccLeaf,
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
