

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

## Download contracts and store it persistently
## ============================================
##
## Caveat: The current implementation assumes that a peer that does not
##         deliver some code will not deliver any code.
##
##         This could be fixed by keeping track of downloaded ranges as is
##         done for downloading account ranges.
##

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

      let data = buddy.fetchCodes(kpq.mapIt Hash32.fromBytes(it.key)).valueOr:
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

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template downloadCode*(buddy: SnapPeerRef; info: static[string]): auto =
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
