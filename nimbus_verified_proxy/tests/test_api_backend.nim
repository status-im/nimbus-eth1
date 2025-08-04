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
    blockReceipts: Table[Hash32, seq[ReceiptObject]]
    receipts: Table[Hash32, ReceiptObject]
    transactions: Table[Hash32, TransactionObject]
    logs: Table[FilterOptions, seq[LogObject]]

func init*(T: type TestApiState, chainId: UInt256): T =
  TestApiState(chainId: chainId)

func clear*(t: TestApiState) =
  t.blocks.clear()
  t.nums.clear()
  t.proofs.clear()
  t.accessLists.clear()
  t.codes.clear()
  t.blockReceipts.clear()
  t.receipts.clear()
  t.transactions.clear()
  t.logs.clear()

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

template loadTransaction*(t: TestApiState, txHash: Hash32, tx: TransactionObject) =
  t.transactions[txHash] = tx

template loadReceipt*(t: TestApiState, txHash: Hash32, rx: ReceiptObject) =
  t.receipts[txHash] = rx

template loadBlockReceipts*(
    t: TestApiState, blk: BlockObject, receipts: seq[ReceiptObject]
) =
  t.blockReceipts[blk.hash] = receipts
  t.loadBlock(blk)

template loadBlockReceipts*(
    t: TestApiState, blkHash: Hash32, blkNum: Quantity, receipts: seq[ReceiptObject]
) =
  t.blockReceipts[blkHash] = receipts
  t.nums[blkNum] = blkHash

template loadLogs*(
    t: TestApiState, filterOptions: FilterOptions, logs: seq[LogObject]
) =
  t.logs[filterOptions] = logs

func hash*(x: BlockTag): Hash =
  if x.kind == BlockIdentifierKind.bidAlias:
    return hash(x.alias)
  else:
    return hash(x.number)

func hash*[T](x: SingleOrList[T]): Hash =
  if x.kind == SingleOrListKind.slkSingle:
    return hash(x.single)
  elif x.kind == SingleOrListKind.slkList:
    return hash(x.list)
  else:
    return hash(0)

func hash*(x: FilterOptions): Hash =
  let
    fromHash =
      if x.fromBlock.isSome():
        hash(x.fromBlock.get)
      else:
        hash(0)
    toHash =
      if x.toBlock.isSome():
        hash(x.toBlock.get)
      else:
        hash(0)
    addrHash = hash(x.address)
    topicsHash = hash(x.topics)
    blockHashHash =
      if x.blockHash.isSome():
        hash(x.blockHash.get)
      else:
        hash(0)

  (fromHash xor toHash xor addrHash xor topicsHash xor blockHashHash)

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
      # we directly use number here because the verified proxy should never use aliases
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

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[Opt[seq[ReceiptObject]]] {.async.} =
      # we directly use number here because the verified proxy should never use aliases
      let blkHash = t.nums[blockId.number]
      Opt.some(t.blockReceipts[blkHash])

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
    eth_getTransactionByHash: getTransactionByHashProc,
    eth_getTransactionReceipt: getTransactionReceiptProc,
    eth_getLogs: getLogsProc,
    eth_getBlockReceipts: getBlockReceiptsProc,
  )
