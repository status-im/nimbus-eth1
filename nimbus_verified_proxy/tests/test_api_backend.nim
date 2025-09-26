# nimbus_verified_proxy
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/tables,
  web3/[eth_api, eth_api_types],
  stint,
  ../engine/types,
  json_rpc/[rpcserver, rpcclient]

type
  ProofQuery = (Address, seq[UInt256], Hash32)
  AccessListQuery = (TransactionArgs, Hash32)
  CodeQuery = (Address, Hash32)

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
    blk: BlockObject,
    proof: ProofResponse,
) =
  t.loadBlock(blk)
  t.proofs[(address, slots, blk.hash)] = proof

template loadAccessList*(
    t: TestApiState,
    args: TransactionArgs,
    blk: BlockObject,
    listResult: AccessListResult,
) =
  t.loadBlock(blk)
  t.accessLists[(args, blk.hash)] = listResult

template loadCode*(
    t: TestApiState, address: Address, blk: BlockObject, code: seq[byte]
) =
  t.loadBlock(blk)
  t.codes[(address, blk.hash)] = code

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

# TODO: remove template below after this is resolved
# https://github.com/nim-lang/Nim/issues/25087
template `==`*(x: BlockTag, y: BlockTag): bool =
  hash(x) == hash(y)

func hash*[T](x: SingleOrList[T]): Hash =
  if x.kind == SingleOrListKind.slkSingle:
    return hash(x.single)
  elif x.kind == SingleOrListKind.slkList:
    return hash(x.list)
  else:
    return hash(0)

# TODO: remove template below after this is resolved
# https://github.com/nim-lang/Nim/issues/25087
template `==`*[T](x: SingleOrList[T], y: SingleOrList[T]): bool =
  hash(x) == hash(y)

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

# TODO: remove template below after this is resolved
# https://github.com/nim-lang/Nim/issues/25087
template `==`*(x: FilterOptions, y: FilterOptions): bool =
  hash(x) == hash(y)

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
    ethChainIdProc = proc(): Future[UInt256] {.async: (raises: [CancelledError]).} =
      return t.chainId

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError]).} =
      try:
        if fullTransactions:
          return t.blocks[blkHash]
        else:
          return convToPartialBlock(t.blocks[blkHash])
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[BlockObject] {.async: (raises: [CancelledError]).} =
      try:
        # we directly use number here because the verified proxy should never use aliases
        let blkHash = t.nums[blkNum.number]

        if fullTransactions:
          return t.blocks[blkHash]
        else:
          return convToPartialBlock(t.blocks[blkHash])
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blkNum: BlockTag
    ): Future[ProofResponse] {.async: (raises: [CancelledError]).} =
      try:
        # we directly use number here because the verified proxy should never use aliases
        let blkHash = t.nums[blkNum.number]
        t.proofs[(address, slots, blkHash)]
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    createAccessListProc = proc(
        args: TransactionArgs, blkNum: BlockTag
    ): Future[AccessListResult] {.async: (raises: [CancelledError]).} =
      try:
        # we directly use number here because the verified proxy should never use aliases
        let blkHash = t.nums[blkNum.number]
        t.accessLists[(args, blkHash)]
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getCodeProc = proc(
        address: Address, blkNum: BlockTag
    ): Future[seq[byte]] {.async: (raises: [CancelledError]).} =
      try:
        # we directly use number here because the verified proxy should never use aliases
        let blkHash = t.nums[blkNum.number]
        t.codes[(address, blkHash)]
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[Opt[seq[ReceiptObject]]] {.async: (raises: [CancelledError]).} =
      try:
        # we directly use number here because the verified proxy should never use aliases
        let blkHash = t.nums[blockId.number]
        Opt.some(t.blockReceipts[blkHash])
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[seq[LogObject]] {.async: (raises: [CancelledError]).} =
      try:
        t.logs[filterOptions]
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[TransactionObject] {.async: (raises: [CancelledError]).} =
      try:
        t.transactions[txHash]
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[ReceiptObject] {.async: (raises: [CancelledError]).} =
      try:
        t.receipts[txHash]
      except CatchableError as e:
        raise newException(CancelledError, e.msg)

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
