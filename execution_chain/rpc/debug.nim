# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[json, times],
  json_rpc/rpcserver,
  web3/[eth_api_types, conversions],
  ./rpc_utils,
  ./rpc_types,
  ../common/common,
  ../beacon/web3_eth_conv,
  ../core/tx_pool,
  ../core/chain/forked_chain,
  ../core/executor,
  ../evm/[types, state],
  ../evm/tracer/legacy_tracer,
  ../stateless/[witness_types, witness_generation],
  ../transaction,
  ../transaction/call_evm_rpc

type
  BadBlock = object
    `block`: BlockObject
    generatedBlockAccessList: Opt[BlockAccessList]
    hash: Hash32
    rlp: seq[byte]

  TestBlockSummary = object
    txCount: int
    blobCount: int

BadBlock.useDefaultSerializationIn EthJson

TestBlockSummary.useDefaultSerializationIn EthJson

ExecutionWitnessWithKeys.useDefaultSerializationIn EthJson

type
  TraceOptions = object
    disableStorage:  Opt[bool]
    disableMemory:   Opt[bool]
    disableStack:    Opt[bool]
    disableState:    Opt[bool]
    disableStateDiff: Opt[bool]

TraceOptions.useDefaultSerializationIn EthJson

func isTrue(x: Opt[bool]): bool =
  x.isSome and x.get()

proc traceOptionsToFlags(options: Opt[TraceOptions]): set[TracerFlags] =
  if options.isSome:
    let opts = options.get
    if opts.disableStorage.isTrue:   result.incl TracerFlags.DisableStorage
    if opts.disableMemory.isTrue:    result.incl TracerFlags.DisableMemory
    if opts.disableStack.isTrue:     result.incl TracerFlags.DisableStack
    if opts.disableState.isTrue:     result.incl TracerFlags.DisableState
    if opts.disableStateDiff.isTrue: result.incl TracerFlags.DisableStateDiff

proc traceBlockWith(com: CommonRef, chain: ForkedChainRef, blk: Block,
                    flags: set[TracerFlags]): JsonNode =
  let
    txFrame    = chain.txFrame(blk.header)
    tracerInst = newLegacyTracer(flags)
    vmState    = BaseVMState.new(
      Header(number: blk.header.number - 1), blk.header, com, txFrame, tracerInst)
  defer:
    vmState.dispose()
    txFrame.dispose()
  for tx in blk.transactions:
    let sender = tx.recoverSenderCached().expect("valid signature")
    discard vmState.processTransaction(tx, sender)
  tracerInst.getTracingResult()

proc setupDebugRpc*(com: CommonRef, txPool: TxPoolRef, server: RpcServer) =
  let
    # chainDB = com.db
    chain = txPool.chain

  server.rpc(EthJson):
    proc debug_traceTransaction(data: Hash32, options: Opt[TraceOptions]): JsonNode {.raises: [RpcResponseError].} =
      let
        (blockHash, txId) = chain.txDetailsByTxHash(data).valueOr:
          raise invalidParams("Transaction not found")
        blk = chain.blockByHash(blockHash).valueOr:
          raise invalidParams("Block not found")
      if int(txId) >= blk.transactions.len:
        raise invalidParams("Transaction index out of range")
      let
        flags      = traceOptionsToFlags(options)
        txFrame    = chain.txFrame(blk.header)
        tracerInst = newLegacyTracer(flags)
        vmState    = BaseVMState.new(
          Header(number: blk.header.number - 1), blk.header, com, txFrame)
      defer:
        vmState.dispose()
        txFrame.dispose()
      for idx, tx in blk.transactions:
        if idx == int(txId):
          vmState.tracer = tracerInst
        let sender = tx.recoverSenderCached().expect("valid signature")
        discard vmState.processTransaction(tx, sender)
        if idx == int(txId):
          break
      tracerInst.getTracingResult()

    proc debug_traceBlockByNumber(quantityTag: BlockTag, options: Opt[TraceOptions]): JsonNode {.raises: [RpcResponseError].} =
      let
        header = chain.headerFromTag(quantityTag).valueOr:
          raise invalidParams(error)
        blk = chain.blockByHash(header.computeBlockHash()).valueOr:
          raise invalidParams("Block not found")
      traceBlockWith(com, chain, blk, traceOptionsToFlags(options))

    proc debug_traceBlockByHash(data: Hash32, options: Opt[TraceOptions]): JsonNode {.raises: [RpcResponseError].} =
      let blk = chain.blockByHash(data).valueOr:
        raise invalidParams("Block not found")
      traceBlockWith(com, chain, blk, traceOptionsToFlags(options))

    proc debug_traceCall(args: TransactionArgs, quantityTag: BlockTag, options: Opt[TraceOptions]): JsonNode {.raises: [RpcResponseError].} =
      let
        header     = chain.headerFromTag(quantityTag).valueOr:
          raise invalidParams(error)
        txFrame    = chain.txFrame(header)
        flags      = traceOptionsToFlags(options)
        tracerInst = newLegacyTracer(flags)
        vmState    = BaseVMState.new(
          Header(number: header.number - 1), header, com, txFrame, tracerInst)
      defer:
        vmState.dispose()
        txFrame.dispose()
      discard rpcCallEvm(args, header, vmState).valueOr:
        raise invalidParams(error)
      tracerInst.getTracingResult()

    proc debug_setHead(quantityTag: BlockTag): bool {.async: (raises: [CancelledError, RpcResponseError]).} =
      ## Sets the current head of the local chain by block number, hash or tag.
      ## Blocks above the new head are discarded, but only blocks still held
      ## in memory (above the persisted base) can become the new head.
      ## Note, this is a destructive action and may severely damage your chain.
      ## Use with extreme caution.

      let
        header = chain.headerFromTag(quantityTag).valueOr:
          raise invalidParams(error)
        headHash = header.computeBlockHash()

      if chain.queue.isNil:
        chain.setHead(headHash).isOkOr:
          raise invalidParams(error)
      else:
        (await chain.queueSetHead(headHash)).isOkOr:
          raise invalidParams(error.msg)

      true

    # https://ethereum.github.io/execution-apis/api/methods/debug_getBadBlocks
    proc debug_getBadBlocks(): seq[BadBlock] =
      ## Returns a list of the most recently processed bad blocks.
      var badBlocks: seq[BadBlock]

      let blks = chain.getBadBlocks()
      for b in blks:
        let
          (blk, bal) = b
          blkHash = blk.header.computeBlockHash()

        badBlocks.add BadBlock(
          `block`: populateBlockObject(
            blkHash, blk, chain.getTotalDifficulty(blkHash, blk.header), fullTx = true),
          generatedBlockAccessList: bal.map(proc (bal: auto): auto = bal[]),
          hash: blkHash,
          rlp: rlp.encode(blk))

      badBlocks

    # https://ethereum.github.io/execution-apis/api/methods/debug_getRawBlock
    proc debug_getRawBlock(blockTag: BlockTag): seq[byte] {.raises: [RpcResponseError].} =
      ## Returns an RLP-encoded block.
      let blockFromTag = chain.blockFromTag(blockTag).valueOr:
        raise invalidParams(error)

      rlp.encode(blockFromTag)

    # https://ethereum.github.io/execution-apis/api/methods/debug_getRawHeader
    proc debug_getRawHeader(blockTag: BlockTag): seq[byte] {.raises: [RpcResponseError, RlpError].} =
      ## Returns an RLP-encoded header.
      let header = chain.headerFromTag(blockTag).valueOr:
        raise invalidParams(error)
      rlp.encode(header)

    # https://ethereum.github.io/execution-apis/api/methods/debug_getRawReceipts
    proc debug_getRawReceipts(blockTag: BlockTag): seq[seq[byte]] {.raises: [RpcResponseError, RlpError].} =
      ## Returns an array of EIP-2718 binary-encoded receipts.
      let header = chain.headerFromTag(blockTag).valueOr:
        raise invalidParams(error)
      let txFrame = chain.txFrame(header)
      var res: seq[seq[byte]]
      for receipt in txFrame.getReceipts(header.receiptsRoot):
        res.add rlp.encode(receipt.to(Receipt))

      res

    # https://ethereum.github.io/execution-apis/api/methods/debug_getRawTransaction
    # we take a string input instead of a hex as in that manner we can preverse the raw json input
    # which later allows us to check for the existence of 0x,which the spec expects in a valid input
    proc debug_getRawTransaction(txHashHex: string): seq[byte] {.raises: [RpcResponseError, ValueError, RlpError].} =
      ## Returns an EIP-2718 binary-encoded transaction.
      # TODO: remove manual validation when upstream parsing decoding reports strict
      # hex input failures .
      if not txHashHex.startsWith("0x"):
        raise invalidParams("invalid argument 0: hex string without 0x prefix")

      let txHash =
        try:
          Hash32.fromHex(txHashHex)
        except ValueError as exc:
          raise invalidParams("invalid argument 0: " & exc.msg)

      let res = txPool.getItem(txHash)
      if res.isOk:
        return rlp.encode(res.get().tx)

      let
        (blockHash, txId) = chain.txDetailsByTxHash(txHash).valueOr:
          raise newException(ValueError, "Transaction not found")
        blk = chain.blockByHash(blockHash).valueOr:
          raise newException(ValueError, "Block not found")

      if blk.transactions.len <= int(txId):
        raise newException(ValueError, "Transaction not found")

      rlp.encode(blk.transactions[txId])

    proc debug_getRawBlockAccessList(quantityTag: BlockTag): seq[byte] {.raises: [ValueError].} =
      ## Returns an RLP-encoded block access list by block number, tag or block hash.
      let header = chain.headerFromTag(quantityTag).valueOr:
        raise newException(ValueError, error)

      if not com.isAmsterdamOrLater(header.timestamp):
        raise newException(ValueError, "Resource not found")

      let bal = chain.getBlockAccessList(header.computeRlpHash()).valueOr:
        if header.number <= chain.resolvedFinNumber:
          raise newException(ValueError, "Pruned history unavailable")
        else:
          raise newException(ValueError, "Resource not found")

      rlp.encode(bal)

    # Execution Witness endpoints - not specified in the Execution API

    proc debug_executionWitness(quantityTag: BlockTag): ExecutionWitnessWithKeys {.raises: [ValueError].} =
      ## Returns an execution witness for the given block number.
      let header = chain.headerFromTag(quantityTag).valueOr:
        raise newException(ValueError, "Header not found")

      chain.getExecutionWitness(header.computeBlockHash()).valueOr:
        raise newException(ValueError, error)

    proc debug_executionWitnessByBlockHash(blockHash: Hash32): ExecutionWitnessWithKeys {.raises: [ValueError].} =
      ## Returns an execution witness for the given block hash.
      chain.getExecutionWitness(blockHash).valueOr:
        raise newException(ValueError, error)

    # Custom debug endpoints - not specified in the Execution API

    proc debug_txPoolDump(): JsonNode {.raises: [KeyError].} =
      ## Returns a dump of the transaction pool state including per-sender
      ## transaction details sorted by effective tip.
      let
        poolBaseFee = txPool.baseFee
        now = getTime().utc.toTime

      var senders = newJObject()

      for item in txPool.allItems:
        let
          senderHex = $item.sender
          tip = item.tx.effectiveGasTip(Opt.some(poolBaseFee.u256))
          age = now - item.time
          accountNonce = txPool.getNonce(item.sender)

        var txNode = newJObject()
        txNode["hash"] = newJString($item.id)
        txNode["nonce"] = newJInt(item.nonce.int64)
        txNode["accountNonce"] = newJInt(accountNonce.int64)
        txNode["type"] = newJString($item.tx.txType)
        txNode["gasLimit"] = newJInt(item.tx.gasLimit.int64)
        txNode["maxFeePerGas"] = newJInt(item.tx.maxFeePerGasNorm.int64)
        txNode["maxPriorityFeePerGas"] = newJInt(item.tx.maxPriorityFeePerGasNorm.int64)
        txNode["effectiveTip"] = newJInt(tip.int64)
        txNode["value"] = newJString($item.tx.value)
        txNode["age"] = newJString($age)

        let wv = item.wrapperVersion
        if wv.isSome:
          txNode["wrapperVersion"] = newJString($wv.get)
          txNode["numBlobs"] = newJInt(item.tx.versionedHashes.len.int64)
          txNode["maxFeePerBlobGas"] = newJString($item.tx.maxFeePerBlobGas)

        if not senders.hasKey(senderHex):
          senders[senderHex] = newJArray()
        senders[senderHex].add(txNode)

      var res = newJObject()
      res["totalTxs"] = newJInt(txPool.len.int64)
      res["senderCount"] = newJInt(txPool.senderCount.int64)
      res["baseFee"] = newJInt(poolBaseFee.int64)
      res["senders"] = senders
      res

    proc debug_buildTestBlock(): TestBlockSummary {.raises: [ValueError].} =
      ## Assembles a block from the current transaction pool using the
      ## production block-building path (TxPoolRef.assembleBlock).
      ## Returns the number of transactions and blobs that were packed.
      let latestHeadHash = chain.latest.hash
      let bundle = txPool.assembleBlock(parentHash = latestHeadHash).valueOr:
        raise newException(ValueError, error)
      let blobCount =
        if bundle.blobsBundle.isNil: 0
        else: bundle.blobsBundle.blobs.len
      TestBlockSummary(
        txCount: bundle.blk.transactions.len,
        blobCount: blobCount,
      )
