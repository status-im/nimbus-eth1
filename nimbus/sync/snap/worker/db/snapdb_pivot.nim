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
  #chronicles,
  eth/[common, rlp],
  stew/results,
  ../../range_desc,
  "."/[hexary_error, snapdb_desc, snapdb_persistent]

{.push raises: [Defect].}

#logScope:
#  topics = "snap-db"

type
  SnapDbPivotRegistry* = object
    predecessor*: NodeKey         ## Predecessor key in chain
    header*: BlockHeader          ## Pivot state, containg state root
    nAccounts*: uint64            ## Imported # of accounts
    nSlotLists*: uint64           ## Imported # of account storage tries
    dangling*: seq[Blob]          ## Dangling nodes in accounts trie
    slotAccounts*: seq[NodeKey]   ## List of accounts with storage slots
    coverage*: uint8              ## coverage factor, 255 => 100%

const
  extraTraceMessages = false or true

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

proc savePivot*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    data: SnapDbPivotRegistry;    ## Registered data record
      ): Result[int,HexaryDbError] =
  ## Register pivot environment
  handleRlpException("savePivot()"):
    let rlpData = rlp.encode(data)
    pv.kvDb.persistentStateRootPut(data.header.stateRoot.to(NodeKey), rlpData)
    return ok(rlpData.len)
  # notreached

proc savePivot*(
    pv: SnapDbRef;                ## Base descriptor on `BaseChainDB`
    header: BlockHeader;          ## Pivot state, containg state root
    nAccounts: uint64;            ## Imported # of accounts
    nSlotLists: uint64;           ## Imported # of account storage tries
    dangling: seq[Blob];          ## Dangling nodes in accounts trie
    slotAccounts: seq[NodeKey];   ## List of accounts with storage slots
    coverage: uint8;              ## coverage factor, 255 => 100%
      ): Result[int,HexaryDbError] =
  ## Variant of `savePivot()`
  result = pv.savePivot SnapDbPivotRegistry(
    header:       header,
    nAccounts:    nAccounts,
    nSlotLists:   nSlotLists,
    dangling:     dangling,
    slotAccounts: slotAccounts,
    coverage:     coverage)

proc recoverPivot*(
  pv: SnapDbRef;                  ## Base descriptor on `BaseChainDB`
  stateRoot: NodeKey;             ## Check for a particular state root
    ): Result[SnapDbPivotRegistry,HexaryDbError] =
  ## Restore pivot environment for a particular state root.
  let rc = pv.kvDb.persistentStateRootGet(stateRoot)
  if rc.isOk:
    handleRlpException("recoverPivot()"):
      var r = rlp.decode(rc.value.data, SnapDbPivotRegistry)
      r.predecessor = rc.value.key
      return ok(r)
  err(StateRootNotFound)

proc recoverPivot*(
  pv: SnapDbRef;                  ## Base descriptor on `BaseChainDB`
    ): Result[SnapDbPivotRegistry,HexaryDbError] =
  ## Restore pivot environment that was saved latest.
  let rc = pv.kvDb.persistentStateRootGet(NodeKey.default)
  if rc.isOk:
    return pv.recoverPivot(rc.value.key)
  err(StateRootNotFound)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
