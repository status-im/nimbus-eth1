# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/tables, stint, minilru, eth/common/eth_types, web3/eth_api_types

type
  ProofQuery = (Address, seq[UInt256], RtBlockIdentifier)
  AccessListQuery = (TransactionArgs, RtBlockIdentifier)
  CodeQuery = (Address, RtBlockIdentifier)

  MockEthApi = object
    fullBlocksByHash: Table[Hash32, BlockObject]
    blocksByHash: Table[Hash32, BlockObject]
    fullBlocksByNumber: Table[RtBlockIdentifier, BlockObject]
    blocksByNumber: Table[RtBlockIdentifier, BlockObject]
    proofs: Table[ProofQuery, ProofResponse]
    accessLists: Table[AccessListQuery, AccessListResult]
    codes: Table[CodeQuery, seq[byte]]

func init*(T: type MockEthApi): T =
  MockEthApi(
    fullBlocksByHash: initTable[Hash32, BlockObject](),
    blocksByHash: initTable[Hash32, BlockObject](),
    fullBlocksByNumber: initTable[RtBlockIdentifier, BlockObject](),
    blocksByNumber: initTable[RtBlockIdentifier, BlockObject](),
    proofs: initTable[ProofQuery, ProofResponse](),
    accessLists: initTable[AccessListQuery, AccessListResult](),
    codes: initTable[CodeQuery, seq[byte]](),
  )

template loadFullBlocks*(m: var MockEthApi, blkHash: Hash32, blk: BlockObject) =
  m.fullBlocksByHash[blkHash] = blk

template loadFullBlocks*(
    m: var MockEthApi, blkNum: RtBlockIdentifier, blk: BlockObject
) =
  m.fullBlockByNumber[blkNum] = blk

template loadBlocks*(m: var MockEthApi, blkHash: Hash32, blk: BlockObject) =
  m.blocksByHash[blkHash] = blk

template loadBlocks*(m: var MockEthApi, blkNum: RtBlockIdentifier, blk: BlockObject) =
  m.blockByNumber[blkNum] = blk

template loadProofs*(
    m: var MockEthApi,
    address: Address,
    slots: seq[UInt256],
    blockId: RtBlockIdentifier,
    proof: ProofResponse,
) =
  m.proofs[(address, slots, blockId)] = proof

template loadAccessLists*(
    m: var MockEthApi,
    args: TransactionArgs,
    blockId: RtBlockIdentifier,
    listResult: AccessListResult,
) =
  m.accessLists[(args, blockId)] = listResult

template loadCodes*(
    m: var MockEthApi, address: Address, blockId: RtBlockIdentifier, code: seq[byte]
) =
  m.codes[(address, blockId)] = code

proc eth_getBlockByHash*(
    m: MockEthApi, blkHash: Hash32, fullTransactions: bool
): BlockObject =
  if fullTransactions:
    return m.fullBlocksByHash[blkHash]
  else:
    return m.blocksByHash[blkHash]

proc eth_getBlockByNumber*(
    m: MockEthApi, blkNum: RtBlockIdentifier, fullTransactions: bool
): BlockObject =
  if fullTransactions:
    return m.fullBlocksByNumber.getOrDefault(blkNum)
  else:
    return m.blocksByNumber.getOrDefault(blkNum)

proc eth_getProof*(
    m: MockEthApi, address: Address, slots: seq[UInt256], blockId: RtBlockIdentifier
): ProofResponse =
  let
    key = (address, slots, blockId)
    res = m.proofs[key]

  return res

proc eth_createAccessList*(
    m: MockEthApi, args: TransactionArgs, blockId: RtBlockIdentifier
): AccessListResult =
  let
    key = (args, blockId)
    res = m.accessLists[key]

  return res

proc eth_getCode*(
    m: MockEthApi, address: Address, blockId: RtBlockIdentifier
): seq[byte] =
  let
    key = (address, blockId)
    res = m.codes[key]

  return res
