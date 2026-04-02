# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}
import
  results,
  eth/eip1559,
  eth/common/times,
  eth/common/transactions,
  web3/eth_api_types,
  ../common/common,
  ../db/ledger,
  ../evm/state,
  ../evm/types,
  ../core/eip4844,
  ../core/executor/process_transaction,
  ../beacon/web3_eth_conv

type
  GasBudget* = object
    remaining*: GasInt

  Simulator* = object
    baseTime*: uint64
    baseNumber*: uint64
    baseCoinbase*: Address
    baseGasLimit*: GasInt
    com*: CommonRef
    budget*: GasBudget
    validate*: bool

  SanitizedTx = object
    gasCapped: bool
    tx: Transaction

const
  # maxSimulateBlocks is the maximum number of blocks that can be simulated
  # in a single request.
  MAX_SIMULATE_BLOCKS = 256

  # timestampIncrement is the default increment between block timestamps.
  TIMESTAMP_INCREMENT = 12

  zeroBytes32 = system.default(Bytes32)

func cap*(budget: GasBudget, gas: GasInt): GasInt =
  if gas > budget.remaining:
    return budget.remaining
  gas

func initBlockOverridesIfNecessary(overrides: var BlockOverrides, prevNumber: uint64) =
  if overrides.number == 0:
    overrides.number = prevNumber + 1

  if overrides.withdrawals.isNone:
    overrides.withdrawals = Opt.some(newSeq[Withdrawal]())

# MakeHeader returns a new header object with the overridden
# fields.
# Note: MakeHeader ignores BlobBaseFee if set. That's because
# header has no such field.
func makeHeader(o: BlockOverrides, header: Header): Header =
  result = header
  if o.number != 0:
    result.number = o.number

  if o.time != 0:
    result.timestamp = EthTime(o.time)

  if o.gasLimit != 0:
    result.gasLimit = o.gasLimit

  if o.feeRecipient != zeroAddress:
    result.coinbase = o.feeRecipient

  if o.prevRandao != zeroBytes32:
    result.mixHash = o.prevRandao

  if o.baseFeePerGas.isZero.not:
    result.baseFeePerGas = Opt.some(o.baseFeePerGas)

func determineTxType(args: TransactionArgs, defaultType: TxType): TxType =
  let usedType = if args.authorizationList.isSome or defaultType == TxEip7702:
                   TxEip7702
                 elif args.blobVersionedHashes.isSome or defaultType == TxEip4844:
                   TxEip4844
                 elif args.maxFeePerGas.isSome or defaultType == TxEip1559:
                   TxEip1559
                 elif args.accessList.isSome or defaultType == TxEip2930:
                   TxEip2930
                 else:
                   TxLegacy

  # Make it possible to default to newer tx, but use legacy if gasprice is provided
  if args.gasPrice.isSome:
    TxLegacy
  else:
    usedType

func getAuthList(args: TransactionArgs): seq[Authorization] =
  if args.authorizationList.isSome:
    return args.authorizationList.value

func getAccessList(args: TransactionArgs): AccessList =
  if args.accessList.isSome:
    return args.accessList.value

func getBlobHashes(args: TransactionArgs): seq[Hash32] =
  if args.blobVersionedHashes.isSome:
    return args.blobVersionedHashes.value

# ToTransaction converts the arguments to a transaction.
# This assumes that setDefaults has been called.
func toTransaction(args: TransactionArgs, defaultType: TxType): Transaction =
  let usedType = args.determineTxType(defaultType)
  case usedType
  of TxEip7702:
    Transaction(
      txType:               usedType,
      to:                   args.to,
      chainId:              args.chainId.value,
      nonce:                AccountNonce(args.nonce.value),
      gasLimit:             GasInt(args.gas.value),
      maxFeePerGas:         GasInt(args.maxFeePerGas.value),
      maxPriorityFeePerGas: GasInt(args.maxPriorityFeePerGas.value),
      value:                args.value.value,
      payload:              args.payload(),
      accessList:           args.getAccessList(),
      authorizationList:    args.getAuthList(),
    )
  of TxEip4844:
    Transaction(
      txType:               usedType,
      to:                   args.to,
      chainId:              args.chainId.value,
      nonce:                AccountNonce(args.nonce.value),
      gasLimit:             GasInt(args.gas.value),
      maxFeePerGas:         GasInt(args.maxFeePerGas.value),
      maxPriorityFeePerGas: GasInt(args.maxPriorityFeePerGas.value),
      value:                args.value.value,
      payload:              args.payload(),
      accessList:           args.getAccessList(),
      versionedHashes:      args.getBlobHashes(),
      maxFeePerBlobGas:     args.maxFeePerBlobGas.value,
    )
  of TxEip1559:
    Transaction(
      txType:               usedType,
      to:                   args.to,
      chainId:              args.chainId.value,
      nonce:                AccountNonce(args.nonce.value),
      gasLimit:             GasInt(args.gas.value),
      maxFeePerGas:         GasInt(args.maxFeePerGas.value),
      maxPriorityFeePerGas: GasInt(args.maxPriorityFeePerGas.value),
      value:                args.value.value,
      payload:              args.payload(),
      accessList:           args.getAccessList(),
    )
  of TxEip2930:
    Transaction(
      txType:               usedType,
      to:                   args.to,
      chainId:              args.chainId.value,
      nonce:                AccountNonce(args.nonce.value),
      gasLimit:             GasInt(args.gas.value),
      gasPrice:             GasInt(args.gasPrice.value),
      value:                args.value.value,
      payload:              args.payload(),
      accessList:           args.getAccessList(),
    )
  else:
    Transaction(
      txType:               usedType,
      to:                   args.to,
      nonce:                AccountNonce(args.nonce.value),
      gasLimit:             GasInt(args.gas.value),
      gasPrice:             GasInt(args.gasPrice.value),
      value:                args.value.value,
      payload:              args.payload(),
    )

# CallDefaults sanitizes the transaction arguments, often filling in zero values,
# for the purpose of eth_call class of RPC methods.
func callDefaults(args: var TransactionArgs, globalGasCap: uint64, baseFee: Opt[UInt256], chainId: ChainId): Result[void, string] =
  # Reject invalid combinations of pre- and post-1559 fee styles
  if args.gasPrice.isSome and (args.maxFeePerGas.isSome or args.maxPriorityFeePerGas.isSome):
    return err("both gasPrice and (maxFeePerGas or maxPriorityFeePerGas) specified")

  if args.chainId.isNone:
    args.chainId = Opt.some(chainId)
  else:
    if args.chainId.value != chainId:
      return err("chainId does not match node's (have=" &
        $args.chainId.value & ", want=" & $chainId & ")")

  if args.gas.isNone:
    var gas = globalGasCap
    if gas == 0:
      gas = uint64(uint64.high div 2)
    args.gas = Opt.some(w3Qty gas)
  else:
    if globalGasCap > 0 and globalGasCap < uint64(args.gas.value):
      #log.Warn("Caller gas above allowance, capping", "requested", args.Gas, "cap", globalGasCap)
      args.gas = Opt.some(w3Qty globalGasCap)

  if args.nonce.isNone:
    args.nonce = Opt.some(w3Qty 0'u64)

  if args.value.isNone:
    args.value = Opt.some(0.u256)

  if baseFee.isNone:
    # If there's no basefee, then it must be a non-1559 execution
    if args.gasPrice.isNone:
      args.gasPrice = Opt.some(w3Qty 0'u64)
  else:
    # A basefee is provided, necessitating 1559-type execution
    if args.maxFeePerGas.isNone:
      args.maxFeePerGas = Opt.some(w3Qty 0'u64)
    if args.maxPriorityFeePerGas.isNone:
      args.maxPriorityFeePerGas = Opt.some(w3Qty 0'u64)

  if args.maxFeePerBlobGas.isNone and args.blobVersionedHashes.isSome:
    args.maxFeePerBlobGas = Opt.some(0.u256)

  ok()

# sanitizeChain checks the chain integrity. Specifically it checks that
# block numbers and timestamp are strictly increasing, setting default values
# when necessary. Gaps in block numbers are filled with empty blocks.
# Note: It modifies the block's override object.
func sanitizeChain(sim: Simulator, blocks: openArray[BlockStateCall]): Result[seq[BlockStateCall], string] =
  var
    res           = newSeqOfCap[BlockStateCall](blocks.len)
    prevNumber    = sim.baseNumber
    prevTimestamp = sim.baseTime

  for blkTmp in blocks:
    var blk = blkTmp
    if blk.blockOverrides.isNone:
      blk.blockOverrides = Opt.some(BlockOverrides())

    initBlockOverridesIfNecessary(blk.blockOverrides.value, prevNumber)

    if prevNumber <= blk.blockOverrides.value.number:
      return err("block numbers must be in order: " &
        $blk.blockOverrides.value.number & " <= " & $prevNumber)

    if blk.blockOverrides.value.number - sim.baseNumber > MAX_SIMULATE_BLOCKS:
      return err("too many blocks")

    if blk.blockOverrides.value.number - prevNumber > 1:
      # Fill the gap with empty blocks.
      let gap = blk.blockOverrides.value.number - prevNumber - 1
      # Assign block number to the empty blocks.
      for i in 0..<gap:
        let
          n = prevNumber + i + 1
          t = prevTimestamp + TIMESTAMP_INCREMENT
          b = BlockStateCall(
            blockOverrides: Opt.some(BlockOverrides(
              number:       n,
              time:         t,
              withdrawals:  Opt.some(newSeq[Withdrawal]()),
            ))
          )
        prevTimestamp = t
        res.add(b)

    # Only append block after filling a potential gap.
    prevNumber = blk.blockOverrides.value.number
    var t: uint64
    if blk.blockOverrides.value.time == 0:
      t = prevTimestamp + TIMESTAMP_INCREMENT
      blk.blockOverrides.value.time = t
    else:
      t = blk.blockOverrides.value.time
      if t <= prevTimestamp:
        return err("block timestamps must be in order: " & $t &
          " <= " & $prevTimestamp)

    prevTimestamp = t
    res.add(blk)

  ok(res)

# makeHeaders makes header object with preliminary fields based on a simulated block.
# Some fields have to be filled post-execution.
# It assumes blocks are in order and numbers have been validated.
func makeHeaders(sim: Simulator, blocks: openArray[BlockStateCall]): Result[seq[Header], string] =
  var
    res    = newSeqOfCap[Header](blocks.len)

  for blk in blocks:
    if blk.blockOverrides.isNone or blk.blockOverrides.value.number == 0:
      return err("empty block number")

    let
      overrides = blk.blockOverrides.get
      timestamp = EthTime(overrides.time)

    var header = makeHeader(overrides, Header(
      ommersHash:       EMPTY_UNCLE_HASH,
      receiptsRoot:     emptyRoot,
      transactionsRoot: emptyRoot,
      coinbase:         sim.baseCoinbase,
      difficulty:       0.u256,
      gasLimit:         sim.baseGasLimit,
    ))

    if sim.com.isShanghaiOrLater(timestamp):
      header.withdrawalsRoot = Opt.some(emptyRoot)

    if sim.com.isCancunOrLater(timestamp):
      header.parentBeaconBlockRoot = Opt.some(overrides.beaconRoot)

    res.add(header)

  ok(res)

proc sanitizeCall(sim: Simulator, args: TransactionArgs,
                  ledger: LedgerRef, header: Header,
                  gasRemaining: GasInt): Result[SanitizedTx, string] =
  var call = args

  if call.nonce.isNone:
    let nonce = ledger.getNonce(call.`from`.get(zeroAddress))
    call.nonce = Opt.some(w3Qty nonce)

  # Let the call run wild unless explicitly specified.
  if call.gas.isNone:
    call.gas = Opt.some(w3Qty gasRemaining)

  if gasRemaining < uint64(call.gas.value):
    return err("block gas limit reached: remaining: " & $gasRemaining &
      ", required: " & $uint64(call.gas.value))

  # Clamp to the cross-block gas budget.
  let
    gas = sim.budget.cap(uint64(call.gas.value))
    gasCapped = gas < uint64(call.gas.value)

  call.gas = Opt.some(w3Qty gas)

  ?call.callDefaults(0, header.baseFeePerGas, sim.com.chainId)

  ok(SanitizedTx(
    gasCapped: gasCapped,
    tx: toTransaction(call, TxEip1559),
  ))

proc applyStateOverrides(ledger: LedgerRef, overrides: Table[Address, OverrideAccount]): Result[void, string] =
  for address, o in overrides:
    if o.state.len > 0 and o.stateDiff.len > 0:
      return err("account " & $address & " has both 'state' and 'stateDiff'")

    if o.nonce.isSome:
      ledger.setNonce(address, o.nonce.value)

    if o.code.isSome:
      ledger.setCode(address, o.code.value)

    if o.balance.isSome:
      ledger.setBalance(address, o.balance.value)

    if o.state.len > 0:
      ledger.clearStorage(address)
      for k, v in o.state:
        ledger.setStorage(address, k, v)

    if o.stateDiff.len > 0:
      for k, v in o.stateDiff:
        ledger.setStorage(address, k, v)

  ok()

proc processBlock(sim: Simulator,
                  txFrame: CoreDbTxRef,
                  blk: BlockStateCall,
                  header: var Header, parent: Header,
                  headers: openArray[Header]): Result[void, string] =
  # Set header fields that depend only on parent block.
  # Parent hash is needed for evm.GetHashFn to work.
  header.parentHash = parent.computeBlockHash
  if sim.com.isLondonOrLater(header.number, header.timestamp):
    # In non-validation mode base fee is set to 0 if it is not overridden.
    # This is because it creates an edge case in EVM where gasPrice < baseFee.
    # Base fee could have been overridden.
    if header.baseFeePerGas.isNone:
      if sim.validate:
        header.baseFeePerGas = Opt.some(calcEip1599BaseFee(
          parent.gasLimit,
          parent.gasUsed,
          parent.baseFeePerGas.get(0.u256))
        )
      else:
        header.baseFeePerGas = Opt.some(0.u256)

  if sim.com.isCancunOrLater(header.timestamp):
    var excess: uint64
    if sim.com.isCancunOrLater(parent.timestamp):
      let fork = sim.com.toEVMFork(header.timestamp)
      excess = calcExcessBlobGas(sim.com, parent, fork)
    header.excessBlobGas = Opt.some(excess)

  let
    blockContext = blockCtx(header)
    vmState = BaseVMState.new(
      parent = parent,
      header = header,
      com    = sim.com,
      txFrame = txFrame,
    )


  #if blk.blockOverrides.BlobBaseFee != nil {
  #  blockContext.BlobBaseFee = block.BlockOverrides.BlobBaseFee.ToInt()
  #}
  #precompiles := sim.activePrecompiles(header)

  # State overrides are applied prior to execution of a block
  ? applyStateOverrides(vmState.ledger, blk.stateOverrides)

  #var (
  #  gp          = core.NewGasPool(blockContext.GasLimit)
  #)

  if sim.com.isPragueOrLater(header.timestamp):
    ? vmState.processParentBlockHash(header.parentHash)

  if header.parentBeaconBlockRoot.isSome:
    ? vmState.processBeaconBlockRoot(header.parentBeaconBlockRoot.value)

  var gasRemaining = header.gasLimit
  for call in blk.calls:
    let sx = ? sim.sanitizeCall(call, vmState.ledger, header, gasRemaining)

    let rc = processTransaction(vmState, item.tx, item.sender, rollbackReads = true)
    if rc.isErr:
      if vmState.classifyPackedNext():
        return ContinueWithNextAccount
      return StopCollecting
  
    # Finish book-keeping
    let inx = pst.packedTxs.len
  
    # Update receipts sequence
    if vmState.receipts.len <= inx:
      vmState.receipts.setLen(inx + receiptsExtensionSize)
  
    vmState.receipts[inx] = vmState.makeReceipt(item.tx.txType, rc.value)
    vmState.allLogs.add rc.value.logEntries
  
  
#[
  # Assign total consumed gas to the header
  header.GasUsed = gp.Used()
  if sim.chainConfig.IsCancun(header.Number, header.Time) {
    header.BlobGasUsed = &blobGasUsed
  }

  # Process EIP-7685 requests
  var requests [][]byte
  if sim.chainConfig.IsPrague(header.Number, header.Time) {
    requests = [][]byte{}
    # EIP-6110
    if err := core.ParseDepositLogs(&requests, allLogs, sim.chainConfig); err != nil {
      return nil, nil, nil, err
    }
    # EIP-7002
    if err := core.ProcessWithdrawalQueue(&requests, evm); err != nil {
      return nil, nil, nil, err
    }
    # EIP-7251
    if err := core.ProcessConsolidationQueue(&requests, evm); err != nil {
      return nil, nil, nil, err
    }
  }
  if requests != nil {
    reqHash := types.CalcRequestsHash(requests)
    header.RequestsHash = &reqHash
  }

  blockBody := &types.Body{
    Transactions: txes,
    Withdrawals:  *block.BlockOverrides.Withdrawals,
  }
  chainHeadReader := &simChainHeadReader{ctx, sim.b}
  b, err := sim.b.Engine().FinalizeAndAssemble(ctx, chainHeadReader, header, sim.state, blockBody, receipts)
  if err != nil {
    return nil, nil, nil, err
  }
  repairLogs(callResults, b.Hash())
  return b, callResults, senders, nil
}

# execute runs the simulation of a series of blocks.
func (sim *simulator) execute(ctx context.Context, blocks []simBlock) ([]*simBlockResult, error) {
  if err := ctx.Err(); err != nil {
    return nil, err
  }
  var (
    cancel  context.CancelFunc
    timeout = sim.b.RPCEVMTimeout()
  )
  if timeout > 0 {
    ctx, cancel = context.WithTimeout(ctx, timeout)
  } else {
    ctx, cancel = context.WithCancel(ctx)
  }
  # Make sure the context is cancelled when the call has completed
  # this makes sure resources are cleaned up.
  defer cancel()

  var err error
  blocks, err = sim.sanitizeChain(blocks)
  if err != nil {
    return nil, err
  }
  # Prepare block headers with preliminary fields for the response.
  headers, err := sim.makeHeaders(blocks)
  if err != nil {
    return nil, err
  }
  var (
    results = make([]*simBlockResult, len(blocks))
    parent  = sim.base
  )
  for bi, block := range blocks {
    result, callResults, senders, err := sim.processBlock(ctx, &block, headers[bi], parent, headers[:bi], timeout)
    if err != nil {
      return nil, err
    }
    headers[bi] = result.Header()
    results[bi] = &simBlockResult{
      fullTx:      sim.fullTx,
      chainConfig: sim.chainConfig,
      Block:       result,
      Calls:       callResults,
      senders:     senders,
    }
    parent = result.Header()
  }
  return results, nil
}
]#
