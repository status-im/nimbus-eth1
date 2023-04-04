# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  eth/[common, rlp],
  stew/results,
  ../../range_desc,
  "."/[hexary_error, snapdb_desc, snapdb_persistent]

{.push raises: [].}

type
  SnapDbPivotRegistry* = object
    predecessor*: NodeKey         ## Predecessor key in chain, auto filled
    header*: BlockHeader          ## Pivot state, containg state root
    nAccounts*: uint64            ## Imported # of accounts
    nSlotLists*: uint64           ## Imported # of account storage tries
    dangling*: seq[Blob]          ## Dangling nodes in accounts trie
    processed*: seq[
      (NodeTag,NodeTag)]          ## Processed acoount ranges
    slotAccounts*: seq[NodeKey]   ## List of accounts with storage slots

const
  extraTraceMessages {.used.} = false or true

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template handleRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError:
    return err(RlpEncoding)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc pivotSaveDB*(
    pv: SnapDbRef;                ## Base descriptor on `ChainDBRef`
    data: SnapDbPivotRegistry;    ## Registered data record
      ): Result[int,HexaryError] =
  ## Register pivot environment
  handleRlpException("pivotSaveDB()"):
    let rlpData = rlp.encode(data)
    pv.kvDb.persistentStateRootPut(data.header.stateRoot.to(NodeKey), rlpData)
    return ok(rlpData.len)
  # notreached

proc pivotRecoverDB*(
  pv: SnapDbRef;                  ## Base descriptor on `ChainDBRef`
  stateRoot: NodeKey;             ## Check for a particular state root
    ): Result[SnapDbPivotRegistry,HexaryError] =
  ## Restore pivot environment for a particular state root.
  let rc = pv.kvDb.persistentStateRootGet(stateRoot)
  if rc.isOk:
    handleRlpException("rpivotRecoverDB()"):
      var r = rlp.decode(rc.value.data, SnapDbPivotRegistry)
      r.predecessor = rc.value.key
      return ok(r)
  err(StateRootNotFound)

proc pivotRecoverDB*(
  pv: SnapDbRef;                  ## Base descriptor on `ChainDBRef`
    ): Result[SnapDbPivotRegistry,HexaryError] =
  ## Restore pivot environment that was saved latest.
  let rc = pv.kvDb.persistentStateRootGet(NodeKey.default)
  if rc.isOk:
    return pv.pivotRecoverDB(rc.value.key)
  err(StateRootNotFound)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
