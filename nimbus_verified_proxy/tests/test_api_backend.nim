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
    blockReceipts: Table[Hash, seq[ReceiptObject]]
    receipts: Table[Hash32, ReceiptObject]
    transactions: Table[Hash32, TransactionObject]
    logs: Table[FilterOptions, seq[LogObject]]

func init*(T: type TestApiState, chainId: UInt256): T =
  TestApiState(
    chainId: chainId,
    fullBlocks: initTable[Hash32, BlockObject](),
    blocks: initTable[Hash32, BlockObject](),
    tags: initTable[Hash, Hash32](),
    proofs: initTable[ProofQuery, ProofResponse](),
    accessLists: initTable[AccessListQuery, AccessListResult](),
    codes: initTable[CodeQuery, seq[byte]](),
    blockReceipts: initTable[Hash, seq[ReceiptObject]](),
    receipts: initTable[Hash32, ReceiptObject](),
    transactions: initTable[Hash32, TransactionObject](),
    logs: initTable[FilterOptions, seq[LogObject]](),
  )

func clear*(t: TestApiState) =
  t.fullBlocks.clear()
  t.blocks.clear()
  t.tags.clear()
  t.proofs.clear()
  t.accessLists.clear()
  t.codes.clear()
  t.blockReceipts.clear()
  t.receipts.clear()
  t.transactions.clear()
  t.logs.clear()

template loadFullBlock*(t: TestApiState, blkHash: Hash32, blk: BlockObject) =
  t.fullBlocks[blkHash] = blk

template loadFullBlock*(t: TestApiState, blkNum: BlockTag, blk: BlockObject) =
  t.tags[hash(blkNum)] = blk.hash
  t.fullBlocks[blk.hash] = blk

template loadBlock*(t: TestApiState, blkHash: Hash32, blk: BlockObject) =
  t.blocks[blkHash] = blk

template loadBlock*(t: TestApiState, blkNum: BlockTag, blk: BlockObject) =
  t.tags[hash(blkNum)] = blk.hash
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

template loadTransactions*(t: TestApiState, txHash: Hash32, tx: TransactionObject) =
  t.transactions[txHash] = tx

template loadReceipts*(t: TestApiState, txHash: Hash32, rx: ReceiptObject) =
  t.receipts[txHash] = rx

template loadBlockReceipts*(
    t: TestApiState, blockId: BlockTag, receipts: seq[ReceiptObject]
) =
  t.blockReceipts[hash(blockId)] = receipts

template loadLogs*(
    t: TestApiState, filterOptions: FilterOptions, logs: seq[LogObject]
) =
  t.logs[filterOptions] = logs

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
      let blkHash = t.tags[hash(blkNum)]

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

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[seq[ReceiptObject]] {.async.} =
      t.blockReceipts[hash(blockId)]

    getLogsProc = proc(filterOptions: FilterOptions): Future[seq[LogObject]] {.async.} =
      t.logs[filterOptions]

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[TransactionObject] {.async.} =
      t.transactions[txHash]

    getTransactionReceiptProc = proc(txHash: Hash32): Future[ReceiptObject] {.async.} =
      t.receipts[txHash]

  EthApiBackend(
    eth_chainId: ethChainIdProc,
    eth_getBlockByHash: getBlockByHashProc,
    eth_getBlockByNumber: getBlockByNumberProc,
    eth_getProof: getProofProc,
    eth_createAccessList: createAccessListProc,
    eth_getCode: getCodeProc,
  )
