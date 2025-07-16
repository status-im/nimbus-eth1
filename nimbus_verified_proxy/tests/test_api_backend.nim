# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/tables,
  web3/[eth_api, eth_api_types],
  stint,
  ../types,
  json_rpc/[rpcserver, rpcclient]

type
  ProofQuery = (Address, seq[UInt256], Hash)
  AccessListQuery = (TransactionArgs, Hash)
  CodeQuery = (Address, Hash)

  TestApiState* = ref object
    chainId: UInt256
    fullBlocks: Table[Hash32, BlockObject]
    blocks: Table[Hash32, BlockObject]
    nums: Table[Quantity, Hash32]
    tags: Table[string, Hash32]
    proofs: Table[ProofQuery, ProofResponse]
    accessLists: Table[AccessListQuery, AccessListResult]
    codes: Table[CodeQuery, seq[byte]]

func init*(T: type TestApiState, chainId: UInt256): T =
  TestApiState(
    chainId: chainId,
    fullBlocks: initTable[Hash32, BlockObject](),
    blocks: initTable[Hash32, BlockObject](),
    nums: initTable[Quantity, Hash32](),
    tags: initTable[string, Hash32](),
    proofs: initTable[ProofQuery, ProofResponse](),
    accessLists: initTable[AccessListQuery, AccessListResult](),
    codes: initTable[CodeQuery, seq[byte]](),
  )

func clear*(t: TestApiState) =
  t.fullBlocks.clear()
  t.blocks.clear()
  t.nums.clear()
  t.tags.clear()
  t.proofs.clear()
  t.accessLists.clear()
  t.codes.clear()

template loadFullBlock*(t: TestApiState, blkHash: Hash32, blk: BlockObject) =
  t.fullBlocks[blkHash] = blk

template loadFullBlock*(t: TestApiState, blkNum: BlockTag, blk: BlockObject) =
  if blkNum.kind == BlockIdentifierKind.bidNumber:
    t.nums[blkNum.number] = blk.hash
    t.fullBlocks[blk.hash] = blk
  else:
    t.tags[alias] = blk.hash
    t.fullBlocks[blk.hash] = blk

template loadBlock*(t: TestApiState, blkHash: Hash32, blk: BlockObject) =
  t.blocks[blkHash] = blk

template loadBlock*(t: TestApiState, blkNum: BlockTag, blk: BlockObject) =
  if blkNum.kind == BlockIdentifierKind.bidNumber:
    t.nums[blkNum.number] = blk.hash
    t.blocks[blk.hash] = blk
  else:
    t.tags[alias] = blk.hash
    t.blocks[blk.hash] = blk

template loadProof*(
    t: TestApiState,
    address: Address,
    slots: seq[UInt256],
    blockId: BlockTag,
    proof: ProofResponse,
) =
  t.proofs[(address, slots, hash(blockId))] = proof

template loadAccessList*(
    t: TestApiState,
    args: TransactionArgs,
    blockId: BlockTag,
    listResult: AccessListResult,
) =
  t.accessLists[(args, hash(blockId))] = listResult

template loadCode*(
    t: TestApiState, address: Address, blockId: BlockTag, code: seq[byte]
) =
  t.codes[(address, hash(blockId))] = code

func hash*(x: BlockTag): Hash =
  if x.kind == BlockIdentifierKind.bidAlias:
    return hash(x.alias)
  else:
    return hash(x.number)

proc initTestApiBackend*(t: TestApiState): EthApiBackend =
  let
    ethChainIdProc = proc(): Future[UInt256] {.async.} =
      return t.chainId

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async.} =
      if fullTransactions:
        return t.fullBlocks[blkHash]
      else:
        return t.blocks[blkHash]

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async.} =
      let blkHash =
        if blkNum.kind == BlockIdentifierKind.bidNumber:
          t.nums[blkNum.number]
        else:
          t.tags[blkNum.alias]

      if fullTransactions:
        return t.fullBlocks[blkHash]
      else:
        return t.blocks[blkHash]

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[ProofResponse] {.async.} =
      t.proofs[(address, slots, hash(blockId))]

    createAccessListProc = proc(
        args: TransactionArgs, blockId: BlockTag
    ): Future[AccessListResult] {.async.} =
      t.accessLists[(args, hash(blockId))]

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[seq[byte]] {.async.} =
      t.codes[(address, hash(blockId))]

  EthApiBackend(
    eth_chainId: ethChainIdProc,
    eth_getBlockByHash: getBlockByHashProc,
    eth_getBlockByNumber: getBlockByNumberProc,
    eth_getProof: getProofProc,
    eth_createAccessList: createAccessListProc,
    eth_getCode: getCodeProc,
  )
