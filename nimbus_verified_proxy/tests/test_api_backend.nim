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
    blocks*: Table[Hash32, BlockObject]
    nums: Table[Quantity, Hash32]
    proofs: Table[ProofQuery, ProofResponse]
    accessLists: Table[AccessListQuery, AccessListResult]
    codes: Table[CodeQuery, seq[byte]]

func init*(T: type TestApiState, chainId: UInt256): T =
  TestApiState(
    chainId: chainId,
    blocks: initTable[Hash32, BlockObject](),
    nums: initTable[Quantity, Hash32](),
    proofs: initTable[ProofQuery, ProofResponse](),
    accessLists: initTable[AccessListQuery, AccessListResult](),
    codes: initTable[CodeQuery, seq[byte]](),
  )

func clear*(t: TestApiState) =
  t.blocks.clear()
  t.nums.clear()
  t.proofs.clear()
  t.accessLists.clear()
  t.codes.clear()

template loadBlock*(t: TestApiState, blk: BlockObject) =
  t.nums[blk.number] = blk.hash
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

func convToPartialBlock(blk: BlockObject): BlockObject =
  var txHashes: seq[TxOrHash]
  for tx in blk.transactions:
    if tx.kind == tohTx:
      txHashes.add(TxOrHash(kind: tohHash, hash: tx.tx.hash))

  return BlockObject(
    number: blk.number,
    hash: blk.hash,
    parentHash: blk.parentHash,
    sha3Uncles: blk.sha3Uncles,
    logsBloom: blk.logsBloom,
    transactionsRoot: blk.transactionsRoot,
    stateRoot: blk.stateRoot,
    receiptsRoot: blk.receiptsRoot,
    miner: blk.miner,
    difficulty: blk.difficulty,
    extraData: blk.extraData,
    gasLimit: blk.gasLimit,
    gasUsed: blk.gasUsed,
    timestamp: blk.timestamp,
    nonce: blk.nonce,
    mixHash: blk.mixHash,
    size: blk.size,
    totalDifficulty: blk.totalDifficulty,
    transactions: txHashes,
    uncles: @[],
    baseFeePerGas: blk.baseFeePerGas,
    withdrawals: Opt.none(seq[Withdrawal]),
    withdrawalsRoot: blk.withdrawalsRoot,
    blobGasUsed: blk.blobGasUsed,
    excessBlobGas: blk.excessBlobGas,
    parentBeaconBlockRoot: blk.parentBeaconBlockRoot,
    requestsHash: blk.requestsHash,
  )

proc initTestApiBackend*(t: TestApiState): EthApiBackend =
  let
    ethChainIdProc = proc(): Future[UInt256] {.async.} =
      return t.chainId

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async.} =
      if fullTransactions:
        return t.blocks[blkHash]
      else:
        return convToPartialBlock(t.blocks[blkHash])

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async.} =
      let blkHash = t.nums[blkNum.number]

      if fullTransactions:
        return t.blocks[blkHash]
      else:
        return convToPartialBlock(t.blocks[blkHash])

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
