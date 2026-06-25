# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  pkg/[chronicles, chronos],
  ../../[helpers, mpt, worker_desc],
  ./code_fetch

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc reCacheContract(
    buddy: SnapPeerRef;
    kpp: KpPair;
    info: static[string];
      ): Opt[void] =
  buddy.ctx.pool.mptAsm.putCodeMissKvt(kpp).isOkOr:
    chronicles.error info & ": Error re-caching missing contract",
      peer=buddy.peer, `error`=error
    return err()
  ok()

proc reCacheContracts(
    buddy: SnapPeerRef;
    kpq: openArray[KpPair];
    info: static[string];
      ): Opt[void] =
  buddy.ctx.pool.mptAsm.putCodeMissKvt(kpq).isOkOr:
    chronicles.error info & ": Error re-caching missing contracts",
      peer=buddy.peer, `error`=error
    return err()
  ok()

proc delCachedContracts(
    buddy: SnapPeerRef;
    kpq: openArray[KpPair];
    info: static[string];
      ): Opt[void] =
  buddy.ctx.pool.mptAsm.delCodeMissKvt(kpq.mapIt it.key).isOkOr:
    chronicles.error info & ": Error deleting missing contracts",
      peer=buddy.peer, `error`=error
    return err()
  ok()

proc persistContracts(
    buddy: SnapPeerRef;
    kvq: openArray[KvPair];
    info: static[string];
      ): Opt[void] =
  buddy.ctx.pool.mptAsm.putCodeKvt(kvq).isOkOr:
    chronicles.error info & ": Error persisting contracts",
      peer=buddy.peer, `error`=error
    return err()
  ok()

# -----------

proc register(state: StateDataRef, acc: seq[(ItemKey,CodeHash)]) =
  for (key,val) in acc:
    state.register(key,val)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getMiissingCodeList(
    buddy: SnapPeerRef;
    info: static[string];
      ): seq[KpPair] =
  ## Fetch some missing contracts
  var kpq: seq[KpPair]
  for w in buddy.ctx.pool.mptAsm.walkCodeMissKvt:
    kpq.add w
    if nFetchByteCodesMax <= kpq.len:
      break
  kpq

proc getKeyValuePair(
    buddy: SnapPeerRef;
    key: openArray[byte];
    code: CodeItem;
    info: static[string];
      ): Opt[KvPair] =
  ## Verify hash, etc
  let
    contract = code.distinctBase
    hash = contract.keccak256                       # verify contracts data
    key1 = Hash32.fromBytes(key)
  if hash != key1:
    error info & ": Contract key/hash mismatch", peer=buddy.peer,
      key=key1.toStr, expected=hash.toStr
    return err()
  ok((@key, contract))


template persistCodesRange(
    buddy: SnapPeerRef;
    info: static[string];
      ): auto =
  var bodyRc = Result[bool,ErrorType].err(ECacheError)
  block body:
    let kpq = buddy.getMiissingCodeList(info)
    var contracts: seq[KvPair]
    if kpq.len == 0:
      bodyRc = typeof(bodyRc).ok(false)             # empty list => all done
      break body

    var nHashError = 0
    buddy.ctx.pool.mptAsm.withMissContracts():
      # Temporarily remove data from disk.
      buddy.delCachedContracts(kpq, info).isOkOr:
        break body

      let
        req = kpq.mapIt(CodeHash Hash32.fromBytes(it.key))
        data = buddy.fetchCodes(req).valueOr:
          buddy.reCacheContracts(kpq, info).isOkOr:
            break body
          bodyRc = typeof(bodyRc).err(error)
          break body

      # Extract contracts or restore omitted contract responses
      for n in 0 ..< data.codes.len:
        if 0 < kpq[n].key.len:
          buddy.getKeyValuePair(kpq[n].key, data.codes[n], info).isErrOr:
            contracts.add value
            continue
          nHashError.inc

        buddy.reCacheContract(kpq[n], info).isOkOr:
          break body

      # Restore omitted node response tail
      template tailData(): auto = kpq.toOpenArray(data.codes.len, kpq.len-1)
      if data.codes.len < kpq.len:
        buddy.reCacheContracts(tailData(), info).isOkOr:
          break body
      # End `withMissContracts()`

    if contracts.len == 0:
      if 0 < nHashError:
        buddy.ctrl.zombie = true
      else:
        buddy.ctrl.stopped = true
      bodyRc = typeof(bodyRc).err(ENoDataAvailable)
      break body

    # Store contracts on MPT assoociated table
    buddy.persistContracts(contracts, info).isOkOr:
      bodyRc = typeof(bodyRc).err(ETrieError)
      break body

    bodyRc = typeof(bodyRc).ok(true)

  bodyRc                                            # return code

# -----------

template downloadImpl(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    accounts: seq[(ItemKey,CodeHash)];              # Acoounts with contracts
    info: static[string];                           # Log message prefix
      ): bool =
  ## Async/template
  ##
  ## The template will return `true` if there were some data that could be
  ## downloaded and processed.
  ##
  var bodyRc = false
  block body:
    let
      ctx = buddy.ctx
      adb = ctx.pool.mptAsm
      peerID = buddy.peerID

      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = state.rootStr          # logging only

    # Fetch storage slots from argument list `accounts`
    var start {.inject.} = 0
    while start < accounts.len:
      let
        accLeft = if start == 0: accounts else: accounts[start .. ^1]
        codeHashes = accLeft.mapIt(it[1])

      # Fetch from network
      let data = buddy.fetchCodes(codeHashes).valueOr:
        state.register accLeft                      # stash data and return
        break body                                  # error => return

      if not state.isOperable():                    # evicted => return
        bodyRc = false                              # ignore downloaded data
        break body

      # Store byte codes on database
      adb.putByteCode(
        state.stateRoot, accLeft[0][0], accLeft[^1][0],
        codeHashes.zip data.codes, peerID).isOkOr:
          state.register(accLeft)                   # stash data and return
          debug info & ": Storing codes failed", peer, root,
            start, nAccLeft=accLeft.len
          break body                                # error => return

      start += data.codes.len
      bodyRc = true                                 # did something
      # End `while`

  bodyRc

template downloadFromQueue(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    info: static[string];                           # Log message prefix
      ): bool =
  ## Async/template
  ##
  ## Process stashed unprocessed byte codes from the state DB.
  ##
  ## The template will return `true` if there were some data that could be
  ## downloaded and processed.
  ##
  var bodyRc = false
  block body:
    var
      accQueue: seq[(ItemKey,CodeHash)]

    for w in state.codeItems(nFetchByteCodesMax):
      accQueue.add (w.key, w.data.code)
      state.delCode w.key

    if 0 < accQueue.len:
      bodyRc = buddy.downloadImpl(state, accQueue, info)

  bodyRc

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template downloadCodePersist*(buddy: SnapPeerRef; info: static[string]): auto =
  ## Async/template
  ##
  ## Fetch and persist missing contracts.
  ##
  var bodyRc = Result[void,ErrorType].err(EGeneric)
  block body:

    while true:
      let ok = buddy.persistCodesRange(info).valueOr:
        bodyRc = typeof(bodyRc).err(error)
        break body
      if not ok:                                    # all done
        break body

    bodyRc = typeof(bodyRc).ok()

  bodyRc                                            # return code


template downloadCodeCache*(
    buddy: SnapPeerRef;                             # Snap peer
    state: StateDataRef;                            # Current state
    accounts: seq[SnapAccount];                     # Acoounts with sub-tries
    info: static[string];                           # Log message prefix
      ) =
  ## Async/template
  ##
  block body:
    if state.isOperable():                          # evicted => return

      # Register downloads for peer synchronisateion
      state.register accounts
         .filterIt(not it.accBody.codeHash.isEmpty)
         .mapIt( (it.accHash.to(ItemKey),
                  it.accBody.codeHash.to(Hash32).to(CodeHash)) )

      if state.hasCodeOrStorage:
        let sdb {.used.} = buddy.ctx.pool.stateDB   # logging only
        trace info & ": code download", peer, `state`=state.toStr(sdb),
          syncState=buddy.syncState

        while not buddy.ctrl.stopped and
              state.hasCodeOrStorage and
              buddy.downloadFromQueue(state, info):
          continue

        trace info & ": Byte code done", peer, `state`=state.toStr(sdb),
          todo=state.hasCodeOrStorage, syncState=buddy.syncState

  discard                                           # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
