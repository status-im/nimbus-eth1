# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  math, eth/common/eth_types,
  ./utils/[macros_gen_opcodes, utils_numeric],
  ./op_codes, ../../common/evmforks,
  ../evm_errors

# Gas Fee Schedule
# Yellow Paper Appendix G - https://ethereum.github.io/yellowpaper/paper.pdf
type
  GasFeeKind* = enum
    GasZero,            # Nothing paid for operations of the set Wzero.
    GasBase,            # Amount of gas to pay for operations of the set Wbase.
    GasVeryLow,         # Amount of gas to pay for operations of the set Wverylow.
    GasLow,             # Amount of gas to pay for operations of the set Wlow.
    GasMid,             # Amount of gas to pay for operations of the set Wmid.
    GasHigh,            # Amount of gas to pay for operations of the set Whigh.
    GasExtCode,         # Amount of gas to pay for operations of the set Wextcode.
    GasBalance,         # Amount of gas to pay for a BALANCE operation.
    GasSload,           # Paid for a SLOAD operation.
    GasJumpDest,        # Paid for a JUMPDEST operation.
    GasSset,            # Paid for an SSTORE operation when the storage value is set to non-zero from zero.
    GasSreset,          # Paid for an SSTORE operation when the storage value’s zeroness remains unchanged or is set to zero.
    RefundsClear,       # Refund given (added into refund counter) when the storage value is set to zero from non-zero.
    RefundSelfDestruct, # Refund given (added into refund counter) for self-destructing an account.
    GasSelfDestruct,    # Amount of gas to pay for a SELFDESTRUCT operation.
    GasCreate,          # Paid for a CREATE operation.
    GasCodeDeposit,     # Paid per byte for a CREATE operation to succeed in placing code into state.
    GasCall,            # Paid for a CALL operation.
    GasCallValue,       # Paid for a non-zero value transfer as part of the CALL operation.
    GasCallStipend,     # A stipend for the called contract subtracted from Gcallvalue for a non-zero value transfer.
    GasNewAccount,      # Paid for a CALL or SELFDESTRUCT operation which creates an account.
    GasExp,             # Partial payment for an EXP operation.
    GasExpByte,         # Partial payment when multiplied by ⌈log256(exponent)⌉ for the EXP operation.
    GasMemory,          # Paid for every additional word when expanding memory.
    GasTXCreate,        # Paid by all contract-creating transactions after the Homestead transition.
    GasTXDataZero,      # Paid for every zero byte of data or code for a transaction.
    GasTXDataNonZero,   # Paid for every non-zero byte of data or code for a transaction.
    GasTransaction,     # Paid for every transaction.
    GasLog,             # Partial payment for a LOG operation.
    GasLogData,         # Paid for each byte in a LOG operation’s data.
    GasLogTopic,        # Paid for each topic of a LOG operation.
    GasSha3,            # Paid for each SHA3 operation.
    GasSha3Word,        # Paid for each word (rounded up) for input data to a SHA3 operation.
    GasCopy,            # Partial payment for COPY operations, multiplied by words copied, rounded up.
    GasBlockhash,       # Payment for BLOCKHASH operation.
    GasExtCodeHash,     # Payment for contract's code hashing
    GasInitcodeWord     # Payment for each word (rounded up) for initcode
    GasWarmStorageRead  # Transient storage read and write cost.

  GasFeeSchedule = array[GasFeeKind, GasInt]

  GasParams* = object
    # Yellow Paper, Appendix H - https://ethereum.github.io/yellowpaper/paper.pdf
    # GasCost is a function of (σ, μ):
    #   - σ is the full system state
    #   - μ is the machine state
    # In practice, we often require the following from
    #   - σ: an account address
    #   - μ: a value popped from the stack or its size.

    kind*: Op
    isNewAccount*: bool
    gasLeft*: GasInt
    gasCallEIP2929*: GasInt
    contractGas*: UInt256
    currentMemSize*: GasNatural
    memOffset*: GasNatural
    memLength*: GasNatural

  GasParamsSs* = object
    currentValue*: UInt256
    originalValue*: UInt256

  GasParamsCr* = object
    currentMemSize*: GasNatural
    memOffset*: GasNatural
    memLength*: GasNatural

  GasCostKind* = enum
    GckInvalidOp,
    GckFixed,
    GckDynamic,
    GckMemExpansion,
    GckCreate,
    GckCall,
    GckLater,
    GckSuicide,
    GckSstore

  # gasRefund of sstore can be a negative number
  SStoreGasResult = tuple[gasCost: GasInt, gasRefund: int64]
  CallGasResult = tuple[gasCost, childGasLimit: GasInt]

  GasCost = object
    case kind*: GasCostKind
    of GckInvalidOp:
      discard
    of GckFixed, GckLater:
      cost*: GasInt
    of GckDynamic:
      d_handler*: proc(value: UInt256): GasInt
                    {.nimcall, gcsafe, raises: [].}
    of GckMemExpansion:
      m_handler*: proc(currentMemSize, memOffset, memLength: GasNatural): GasInt
                    {.nimcall, gcsafe, raises: [].}
    of GckCreate:
      cr_handler*: proc(value: UInt256, params: GasParamsCr): GasInt
                    {.nimcall, gcsafe, raises: [].}
    of GckCall:
      c_handler*: proc(value: UInt256, params: GasParams): EvmResult[CallGasResult]
                    {.nimcall, gcsafe, raises: [].}
      # We use gasCost/gasRefund for:
      #   - Properly log and order cost and refund (for Sstore especially)
      #   - Allow to use unsigned integer in the future
      #   - CALL instruction requires passing the child message gas (Ccallgas in yellow paper)
    of GckSuicide:
      sc_handler*: proc(condition: bool): GasInt
                    {.nimcall, gcsafe, raises: [].}
    of GckSstore:
      ss_handler*: proc(value: UInt256, params: GasParamsSs): SStoreGasResult
                    {.nimcall, gcsafe, raises: [].}

  GasCosts* = array[Op, GasCost]

const
  # From EIP-2929
  ColdSloadCost*         = 2100
  ColdAccountAccessCost* = 2600
  WarmStorageReadCost*   = 100

  # From EIP-2930 (Berlin).
  ACCESS_LIST_STORAGE_KEY_COST* = 1900.GasInt
  ACCESS_LIST_ADDRESS_COST*     = 2400.GasInt

template gasCosts(fork: EVMFork, prefix, ResultGasCostsName: untyped) =

  ## Generate the gas cost for each forks and store them in a const
  ## named `ResultGasCostsName`

  const FeeSchedule = gasFees[fork]

  # ############### Helper functions ##############################

  func `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.inline.} =
    # Input: size (in bytes)

    # Yellow Paper:
    #   Memory expansion cost
    #     = Cmem(μ′i) − Cmem(μi)
    #   μi is memory size before opcode execution
    #   μ'i is the memory size after opcode execution

    #   Cmem(a) ≡ Gmemory · a + a² / 512
    #
    #   Except when memLength = 0, where per eq (297),
    #   M(currentMemSize, f, l) = currentMemSize

    let
      prevWords = GasInt currentMemSize.wordCount
      newWords  = GasInt (memOffset + memLength).wordCount

    if memLength == 0 or newWords <= prevWords:
      # Special subcase of memory-expansion cost
      # currentMemSize - currentMemSize = 0
      # "Referencing a zero length range ... does not require memory to be extended
      #  to the beginning of the range."
      #
      # Also, don't credit EVM code for allocating memory
      # then accessing lots of low memory. memoryGasCost,
      # via go-ethereum, checks for this as special case.
      return 0

    let
      prevCost = prevWords * static(FeeSchedule[GasMemory]) +
        (prevWords ^ 2) shr 9 # div 512
      newCost = newWords * static(FeeSchedule[GasMemory]) +
        (newWords ^ 2) shr 9 # div 512

    # TODO: add logging
    result = max(newCost - prevCost, 0)

  when fork >= FkTangerine:
    func `prefix all_but_one_64th`(gas: GasInt): GasInt {.inline.} =
      ## Computes all but 1/64th
      ## L(n) ≡ n − ⌊n/64⌋ - (floored(n/64))
      # Introduced in EIP-150 - https://github.com/ethereum/EIPs/blob/master/EIPS/eip-150.md

      # Note: The all-but-one-64th calculation should occur after the memory expansion fee is taken
      # https://github.com/ethereum/yellowpaper/pull/442

      result = gas - (gas shr 6)

  # ############### Opcode gas functions ##############################

  func `prefix gasExp`(value: UInt256): GasInt {.nimcall.} =
    ## Value is the exponent

    result = static FeeSchedule[GasExp]
    if not value.isZero:
      result += static(FeeSchedule[GasExpByte]) * (1 + log256(value))

  func `prefix gasCreate`(value: UInt256, params: GasParamsCr): GasInt {.nimcall.} =
    if value.isZero:
      result = static(FeeSchedule[GasCodeDeposit]) * params.memLength
    else:
      result = static(FeeSchedule[GasCreate]) +
        (static(FeeSchedule[GasInitcodeWord]) * params.memLength.wordCount) +
        `prefix gasMemoryExpansion`(params.currentMemSize, params.memOffset, params.memLength)

  func `prefix gasSha3`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =

    result = `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)
    result += static(FeeSchedule[GasSha3]) +
      static(FeeSchedule[GasSha3Word]) * (memLength).wordCount

  func `prefix gasCopy`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = static(FeeSchedule[GasVeryLow]) +
      static(FeeSchedule[GasCopy]) * memLength.wordCount
    result += `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

  func `prefix gasExtCodeCopy`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = static(FeeSchedule[GasExtCode]) +
      static(FeeSchedule[GasCopy]) * memLength.wordCount
    result += `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

  func `prefix gasLoadStore`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = static(FeeSchedule[GasVeryLow])
    result += `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

  func `prefix gasSstore`(value: UInt256, params: GasParamsSs): SStoreGasResult {.nimcall.} =
    ## Value is word to save
    var res: SStoreGasResult
    when fork >= FkBerlin:
      # EIP2929
      const
        SLOAD_GAS = WarmStorageReadCost
        SSTORE_RESET_GAS = 5000 - ColdSloadCost
    else:
      const
        SLOAD_GAS = FeeSchedule[GasSload]
        SSTORE_RESET_GAS = FeeSchedule[GasSreset]

    const
      NoopGas     {.used.} = SLOAD_GAS # if the value doesn't change.
      DirtyGas    {.used.} = SLOAD_GAS # if a dirty value is changed.
      InitGas     {.used.} = FeeSchedule[GasSset]  # from clean zero to non-zero
      InitRefund  {.used.} = FeeSchedule[GasSset] - SLOAD_GAS # resetting to the original zero value
      CleanGas    {.used.} = SSTORE_RESET_GAS # from clean non-zero to something else
      CleanRefund {.used.} = SSTORE_RESET_GAS - SLOAD_GAS # resetting to the original non-zero value
      ClearRefund {.used.} = FeeSchedule[RefundsClear]# clearing an originally existing storage slot

    when fork < FkConstantinople or fork == FkPetersburg:
      let isStorageEmpty = params.currentValue.isZero

      # Gas cost - literal translation of Yellow Paper
      res.gasCost = if value.isZero.not and isStorageEmpty:
                      InitGas
                    else:
                      CleanGas

      # Refund
      if value.isZero and not isStorageEmpty:
        res.gasRefund = ClearRefund
    else:
      # 0. If *gasleft* is less than or equal to 2300, fail the current call.
      # 1. If current value equals new value (this is a no-op), SSTORE_NOOP_GAS gas is deducted.
      # 2. If current value does not equal new value:
      #   2.1. If original value equals current value (this storage slot has not been changed by the current execution context):
      #     2.1.1. If original value is 0, SSTORE_INIT_GAS gas is deducted.
      #     2.1.2. Otherwise, SSTORE_CLEAN_GAS gas is deducted. If new value is 0, add SSTORE_CLEAR_REFUND to refund counter.
      #   2.2. If original value does not equal current value (this storage slot is dirty), SSTORE_DIRTY_GAS gas is deducted. Apply both of the following clauses:
      #     2.2.1. If original value is not 0:
      #       2.2.1.1. If current value is 0 (also means that new value is not 0), subtract SSTORE_CLEAR_REFUND gas from refund counter. We can prove that refund counter will never go below 0.
      #       2.2.1.2. If new value is 0 (also means that current value is not 0), add SSTORE_CLEAR_REFUND gas to refund counter.
      #     2.2.2. If original value equals new value (this storage slot is reset):
      #       2.2.2.1. If original value is 0, add SSTORE_INIT_REFUND to refund counter.
      #       2.2.2.2. Otherwise, add SSTORE_CLEAN_REFUND gas to refund counter.

      # Gas sentry honoured, do the actual gas calculation based on the stored value
      if params.currentValue == value: # noop (1)
        res.gasCost = NoopGas
        return res

      if params.originalValue == params.currentValue:
        if params.originalValue.isZero: # create slot (2.1.1)
          res.gasCost = InitGas
          return res

        if value.isZero: # delete slot (2.1.2b)
          res.gasRefund = ClearRefund

        res.gasCost = CleanGas # write existing slot (2.1.2)
        return res

      if not params.originalValue.isZero:
        if params.currentValue.isZero: # recreate slot (2.2.1.1)
          res.gasRefund -= ClearRefund
        if value.isZero: # delete slot (2.2.1.2)
          res.gasRefund += ClearRefund

      if params.originalValue == value:
        if params.originalValue.isZero: # reset to original inexistent slot (2.2.2.1)
          res.gasRefund += InitRefund
        else: # reset to original existing slot (2.2.2.2)
          res.gasRefund += CleanRefund

      res.gasCost = DirtyGas # dirty update (2.2)
    res

  func `prefix gasLog0`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

    result += static(FeeSchedule[GasLog]) +
      static(FeeSchedule[GasLogData]) * memLength

  func `prefix gasLog1`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

    result += static(FeeSchedule[GasLog]) +
      static(FeeSchedule[GasLogData]) * memLength +
      static(FeeSchedule[GasLogTopic])

  func `prefix gasLog2`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

    result += static(FeeSchedule[GasLog]) +
      static(FeeSchedule[GasLogData]) * memLength +
      static(2 * FeeSchedule[GasLogTopic])

  func `prefix gasLog3`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

    result += static(FeeSchedule[GasLog]) +
      static(FeeSchedule[GasLogData]) * memLength +
      static(3 * FeeSchedule[GasLogTopic])

  func `prefix gasLog4`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

    result += static(FeeSchedule[GasLog]) +
      static(FeeSchedule[GasLogData]) * memLength +
      static(4 * FeeSchedule[GasLogTopic])

  func `prefix gasCall`(value: UInt256, params: GasParams): EvmResult[CallGasResult] {.nimcall.} =
    # From the Yellow Paper, going through the equation from bottom to top
    # https://ethereum.github.io/yellowpaper/paper.pdf#appendix.H
    #
    # More readable info on the subtleties wiki page: https://github.com/ethereum/wiki/wiki/Subtleties#other-operations
    # CALL has a multi-part gas cost:
    #
    # - 700 base
    # - 9000 additional if the value is nonzero
    # - 25000 additional if the destination account does not yet exist
    #
    # The child message of a nonzero-value CALL operation (NOT the top-level message arising from a transaction!)
    # gains an additional 2300 gas on top of the gas supplied by the calling account;
    # this stipend can be considered to be paid out of the 9000 mandatory additional fee for nonzero-value calls.
    # This ensures that a call recipient will always have enough gas to log that it received funds.
    #
    # EIP150 goes over computation: https://github.com/ethereum/eips/issues/150
    #
    # The discussion for the draft EIP-5, which proposes to change the CALL opcode also goes over
    # the current implementation - https://github.com/ethereum/EIPs/issues/8

    # Both gasCost and childGasLimit are always on positive side

    var gasLeft = params.gasLeft
    if gasLeft < params.gasCallEIP2929:
      return err(opErr(OutOfGas))
    gasLeft -= params.gasCallEIP2929

    var gasCost: GasInt = `prefix gasMemoryExpansion`(
                             params.currentMemSize,
                             params.memOffset,
                             params.memLength)
    var childGasLimit: GasInt

    # Cnew_account
    if params.isNewAccount and params.kind == Call:
      when fork < FkSpurious:
        # Pre-EIP161 all account creation calls consumed 25000 gas.
        gasCost += static(FeeSchedule[GasNewAccount])
      else:
        # Afterwards, only those transfering value:
        # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-158.md
        # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
        if not value.isZero:
          gasCost += static(FeeSchedule[GasNewAccount])

    # Cxfer
    if not value.isZero and params.kind in {Call, CallCode}:
      gasCost += static(FeeSchedule[GasCallValue])

    # Cextra
    gasCost += static(FeeSchedule[GasCall])

    if gasLeft < gasCost:
      return err(opErr(OutOfGas))
    gasLeft -= gasCost

    # Cgascap
    when fork >= FkTangerine:
      # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-150.md
      let gas = `prefix all_but_one_64th`(gasLeft)
      if params.contractGas > high(GasInt).u256 or
        gas < params.contractGas.truncate(GasInt):
        childGasLimit = gas
      else:
        childGasLimit = params.contractGas.truncate(GasInt)
    else:
      if params.contractGas > high(GasInt).u256:
        return err(gasErr(GasIntOverflow))
      childGasLimit = params.contractGas.truncate(GasInt)

    if gasCost.u256 + childGasLimit.u256 > high(GasInt).u256:
      return err(gasErr(GasIntOverflow))

    gasCost += childGasLimit

    # Ccallgas - Gas sent to the child message
    if not value.isZero and params.kind in {Call, CallCode}:
      childGasLimit += static(FeeSchedule[GasCallStipend])

    gasCost += params.gasCallEIP2929

    # at this point gasCost and childGasLimit is always > 0
    ok( (gasCost, childGasLimit) )

  func `prefix gasHalt`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    `prefix gasMemoryExpansion`(currentMemSize, memOffset, memLength)

  func `prefix gasSelfDestruct`(condition: bool): GasInt {.nimcall.} =
    result += static(FeeSchedule[GasSelfDestruct])
    when fork >= FkTangerine:
      if condition:
        result += static(FeeSchedule[GasNewAccount])

  func `prefix gasCreate2`(currentMemSize, memOffset, memLength: GasNatural): GasInt {.nimcall.} =
    result = static(FeeSchedule[GasSha3Word]) * (memLength).wordCount

  # ###################################################################################################

  let `ResultGasCostsName`*{.inject, compileTime.}: GasCosts = block:
    # We use a block expression to avoid name redefinition conflicts
    # with "fixed" and "dynamic"

    # Syntactic sugar
    func fixed(gasFeeKind: static[GasFeeKind]): GasCost =
      GasCost(kind: GckFixed, cost: static(FeeSchedule[gasFeeKind]))

    func fixedOrLater(gasFeeKind: static[GasFeeKind]): GasCost =
      when fork < FkBerlin:
        GasCost(kind: GckFixed, cost: static(FeeSchedule[gasFeeKind]))
      else:
        # GckLater is processed by the opcode
        GasCost(kind: GckLater, cost: static(FeeSchedule[gasFeeKind]))

    func dynamic(handler: proc(value: UInt256): GasInt
                  {.nimcall, gcsafe, raises: [].}): GasCost =
        GasCost(kind: GckDynamic, d_handler: handler)

    func memExpansion(handler: proc(currentMemSize, memOffset, memLength: GasNatural): GasInt
                  {.nimcall, gcsafe, raises: [].}): GasCost =
      GasCost(kind: GckMemExpansion, m_handler: handler)

    func handleCall(handler: proc(value: UInt256, gasParams: GasParams): EvmResult[CallGasResult]
                  {.nimcall, gcsafe, raises: [].}): GasCost =
      GasCost(kind: GckCall, c_handler: handler)

    func handleCreate(handler: proc(value: UInt256, gasParams: GasParamsCr): GasInt
                  {.nimcall, gcsafe, raises: [].}): GasCost =
      GasCost(kind: GckCreate, cr_handler: handler)

    func handleSuicide(handler: proc(condition: bool): GasInt
                  {.nimcall, gcsafe, raises: [].}): GasCost =
      GasCost(kind: GckSuicide, sc_handler: handler)

    func handleSstore(handler: proc(value: UInt256, gasParams: GasParamsSs): SStoreGasResult
                  {.nimcall, gcsafe, raises: [].}): GasCost =
      GasCost(kind: GckSstore, ss_handler: handler)

    # Returned value
    fill_enum_table_holes(Op, GasCost(kind: GckInvalidOp)):
      [
          # 0s: Stop and Arithmetic Operations
          Stop:            fixed GasZero,
          Add:             fixed GasVeryLow,
          Mul:             fixed GasLow,
          Sub:             fixed GasVeryLow,
          Div:             fixed GasLow,
          Sdiv:            fixed GasLow,
          Mod:             fixed GasLow,
          Smod:            fixed GasLow,
          Addmod:          fixed GasMid,
          Mulmod:          fixed GasMid,
          Exp:             dynamic `prefix gasExp`,
          SignExtend:      fixed GasLow,

          # 10s: Comparison & Bitwise Logic Operations
          Lt:              fixed GasVeryLow,
          Gt:              fixed GasVeryLow,
          Slt:             fixed GasVeryLow,
          Sgt:             fixed GasVeryLow,
          Eq:              fixed GasVeryLow,
          IsZero:          fixed GasVeryLow,
          And:             fixed GasVeryLow,
          Or:              fixed GasVeryLow,
          Xor:             fixed GasVeryLow,
          Not:             fixed GasVeryLow,
          Byte:            fixed GasVeryLow,
          Shl:             fixed GasVeryLow,
          Shr:             fixed GasVeryLow,
          Sar:             fixed GasVeryLow,

          # 20s: SHA3
          Sha3:            memExpansion `prefix gasSha3`,

          # 30s: Environmental Information
          Address:         fixed GasBase,
          Balance:         fixedOrLater GasBalance,
          Origin:          fixed GasBase,
          Caller:          fixed GasBase,
          CallValue:       fixed GasBase,
          CallDataLoad:    fixed GasVeryLow,
          CallDataSize:    fixed GasBase,
          CallDataCopy:    memExpansion `prefix gasCopy`,
          CodeSize:        fixed GasBase,
          CodeCopy:        memExpansion `prefix gasCopy`,
          GasPrice:        fixed GasBase,
          ExtCodeSize:     fixedOrLater GasExtCode,
          ExtCodeCopy:     memExpansion `prefix gasExtCodeCopy`,
          ReturnDataSize:  fixed GasBase,
          ReturnDataCopy:  memExpansion `prefix gasCopy`,
          ExtCodeHash:     fixedOrLater GasExtCodeHash,

          # 40s: Block Information
          Blockhash:       fixed GasBlockhash,
          Coinbase:        fixed GasBase,
          Timestamp:       fixed GasBase,
          Number:          fixed GasBase,
          Difficulty:      fixed GasBase,
          GasLimit:        fixed GasBase,
          ChainIdOp:       fixed GasBase,
          SelfBalance:     fixed GasLow,
          BaseFee:         fixed GasBase,
          BlobHash:        fixed GasVeryLow,
          BlobBaseFee:     fixed GasBase,

          # 50s: Stack, Memory, Storage and Flow Operations
          Pop:            fixed GasBase,
          Mload:          memExpansion `prefix gasLoadStore`,
          Mstore:         memExpansion `prefix gasLoadStore`,
          Mstore8:        memExpansion `prefix gasLoadStore`,
          Sload:          fixedOrLater GasSload,
          Sstore:         handleSstore `prefix gasSstore`,
          Jump:           fixed GasMid,
          JumpI:          fixed GasHigh,
          Pc:             fixed GasBase,
          Msize:          fixed GasBase,
          Gas:            fixed GasBase,
          JumpDest:       fixed GasJumpDest,

          # 5c & 5d: Transient storage operations
          Tload:          fixed GasWarmStorageRead,
          Tstore:         fixed GasWarmStorageRead,

          # 5e: Memory copy
          Mcopy:          memExpansion `prefix gasCopy`,

          # 5f, 60s & 70s: Push Operations
          Push0:          fixed GasBase,
          Push1:          fixed GasVeryLow,
          Push2:          fixed GasVeryLow,
          Push3:          fixed GasVeryLow,
          Push4:          fixed GasVeryLow,
          Push5:          fixed GasVeryLow,
          Push6:          fixed GasVeryLow,
          Push7:          fixed GasVeryLow,
          Push8:          fixed GasVeryLow,
          Push9:          fixed GasVeryLow,
          Push10:         fixed GasVeryLow,
          Push11:         fixed GasVeryLow,
          Push12:         fixed GasVeryLow,
          Push13:         fixed GasVeryLow,
          Push14:         fixed GasVeryLow,
          Push15:         fixed GasVeryLow,
          Push16:         fixed GasVeryLow,
          Push17:         fixed GasVeryLow,
          Push18:         fixed GasVeryLow,
          Push19:         fixed GasVeryLow,
          Push20:         fixed GasVeryLow,
          Push21:         fixed GasVeryLow,
          Push22:         fixed GasVeryLow,
          Push23:         fixed GasVeryLow,
          Push24:         fixed GasVeryLow,
          Push25:         fixed GasVeryLow,
          Push26:         fixed GasVeryLow,
          Push27:         fixed GasVeryLow,
          Push28:         fixed GasVeryLow,
          Push29:         fixed GasVeryLow,
          Push30:         fixed GasVeryLow,
          Push31:         fixed GasVeryLow,
          Push32:         fixed GasVeryLow,

          # 80s: Duplication Operations
          Dup1:           fixed GasVeryLow,
          Dup2:           fixed GasVeryLow,
          Dup3:           fixed GasVeryLow,
          Dup4:           fixed GasVeryLow,
          Dup5:           fixed GasVeryLow,
          Dup6:           fixed GasVeryLow,
          Dup7:           fixed GasVeryLow,
          Dup8:           fixed GasVeryLow,
          Dup9:           fixed GasVeryLow,
          Dup10:          fixed GasVeryLow,
          Dup11:          fixed GasVeryLow,
          Dup12:          fixed GasVeryLow,
          Dup13:          fixed GasVeryLow,
          Dup14:          fixed GasVeryLow,
          Dup15:          fixed GasVeryLow,
          Dup16:          fixed GasVeryLow,

          # 90s: Exchange Operations
          Swap1:          fixed GasVeryLow,
          Swap2:          fixed GasVeryLow,
          Swap3:          fixed GasVeryLow,
          Swap4:          fixed GasVeryLow,
          Swap5:          fixed GasVeryLow,
          Swap6:          fixed GasVeryLow,
          Swap7:          fixed GasVeryLow,
          Swap8:          fixed GasVeryLow,
          Swap9:          fixed GasVeryLow,
          Swap10:         fixed GasVeryLow,
          Swap11:         fixed GasVeryLow,
          Swap12:         fixed GasVeryLow,
          Swap13:         fixed GasVeryLow,
          Swap14:         fixed GasVeryLow,
          Swap15:         fixed GasVeryLow,
          Swap16:         fixed GasVeryLow,

          # a0s: Logging Operations
          Log0:           memExpansion `prefix gasLog0`,
          Log1:           memExpansion `prefix gasLog1`,
          Log2:           memExpansion `prefix gasLog2`,
          Log3:           memExpansion `prefix gasLog3`,
          Log4:           memExpansion `prefix gasLog4`,

          # f0s: System operations
          Create:         handleCreate `prefix gasCreate`,
          Call:           handleCall `prefix gasCall`,
          CallCode:       handleCall `prefix gasCall`,
          Return:         memExpansion `prefix gasHalt`,
          DelegateCall:   handleCall `prefix gasCall`,
          Create2:        memExpansion `prefix gasCreate2`,
          StaticCall:     handleCall `prefix gasCall`,
          Revert:         memExpansion `prefix gasHalt`,
          Invalid:        fixed GasZero,
          SelfDestruct:   handleSuicide `prefix gasSelfDestruct`
        ]

# Generate the fork-specific gas costs tables
const
  BaseGasFees: GasFeeSchedule = [
    # Fee Schedule for the initial Ethereum forks
    GasZero:            0.GasInt,
    GasBase:            2,
    GasVeryLow:         3,
    GasLow:             5,
    GasMid:             8,
    GasHigh:            10,
    GasExtCode:         20,     # Changed to 700 in Tangerine (EIP150)
    GasBalance:         20,     # Changed to 400 in Tangerine (EIP150)
    GasSload:           50,     # Changed to 200 in Tangerine (EIP150)
    GasJumpDest:        1,
    GasSset:            20_000,
    GasSreset:          5_000,
    RefundsClear:       15_000,
    RefundSelfDestruct: 24_000,
    GasSelfDestruct:    0,      # Changed to 5000 in Tangerine (EIP150)
    GasCreate:          32000,
    GasCodeDeposit:     200,
    GasCall:            40,     # Changed to 700 in Tangerine (EIP150)
    GasCallValue:       9000,
    GasCallStipend:     2300,
    GasNewAccount:      25_000,
    GasExp:             10,
    GasExpByte:         10,     # Changed to 50 in Spurious Dragon (EIP160)
    GasMemory:          3,
    GasTXCreate:        0,      # Changed to 32000 in Homestead (EIP2)
    GasTXDataZero:      4,
    GasTXDataNonZero:   68,
    GasTransaction:     21000,
    GasLog:             375,
    GasLogData:         8,
    GasLogTopic:        375,
    GasSha3:            30,
    GasSha3Word:        6,
    GasCopy:            3,
    GasBlockhash:       20,
    GasExtCodeHash:     400,
    GasInitcodeWord:    0,      # Changed to 2 in EIP-3860
    GasWarmStorageRead: WarmStorageReadCost
  ]

# Create the schedule for each forks
func homesteadGasFees(previousFees: GasFeeSchedule): GasFeeSchedule =
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-2.md
  result = previousFees
  result[GasTXCreate] = 32000

func tangerineGasFees(previousFees: GasFeeSchedule): GasFeeSchedule =
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-150.md
  result = previousFees
  result[GasExtCode]      = 700
  result[GasSload]        = 200
  result[GasSelfDestruct] = 5000
  result[GasBalance]      = 400
  result[GasCall]         = 700

func spuriousGasFees(previousFees: GasFeeSchedule): GasFeeSchedule =
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-160.md
  result = previousFees
  result[GasExpByte]      = 50

func istanbulGasFees(previousFees: GasFeeSchedule): GasFeeSchedule =
  # https://eips.ethereum.org/EIPS/eip-1884
  result = previousFees
  result[GasSload]        = 800
  result[GasExtCodeHash]  = 700
  result[GasBalance]      = 700
  result[GasTXDataNonZero]= 16

func berlinGasFees(previousFees: GasFeeSchedule): GasFeeSchedule =
  # https://eips.ethereum.org/EIPS/eip-2929
  result = previousFees

  # these opcodes gas are calculated inside opcode
  result[GasBalance]     = 0
  result[GasExtCodeHash] = 0
  result[GasExtCode]     = 0

  # SLOAD gasCost become fully dynamic, see sloadEIP2929
  result[GasSload]        = 0
  result[GasCall]         = WarmStorageReadCost

func londonGasFees(previousFees: GasFeeSchedule): GasFeeSchedule =
  result = previousFees
  # EIP-3529 RefundsClear(4800) =
  # EIP-2929(5000 - ColdSloadCost) +
  # EIP-2930(ACCESS_LIST_STORAGE_KEY_COST)
  result[RefundsClear] =
    5000 - ColdSloadCost +
    ACCESS_LIST_STORAGE_KEY_COST

func shanghaiGasFees(previousFees: GasFeeSchedule): GasFeeSchedule =
  result = previousFees
  result[GasInitcodeWord] = 2.GasInt  # INITCODE_WORD_COST from EIP-3860

const
  HomesteadGasFees = BaseGasFees.homesteadGasFees
  TangerineGasFees = HomesteadGasFees.tangerineGasFees
  SpuriousGasFees = TangerineGasFees.spuriousGasFees
  IstanbulGasFees = SpuriousGasFees.istanbulGasFees
  BerlinGasFees = IstanbulGasFees.berlinGasFees
  LondonGasFees = BerlinGasFees.londonGasFees
  ShanghaiGasFees = LondonGasFees.shanghaiGasFees

  gasFees*: array[EVMFork, GasFeeSchedule] = [
    FkFrontier: BaseGasFees,
    FkHomestead: HomesteadGasFees,
    FkTangerine: TangerineGasFees,
    FkSpurious: SpuriousGasFees,
    FkByzantium: SpuriousGasFees,
    FkConstantinople: SpuriousGasFees,
    FkPetersburg: SpuriousGasFees,
    FkIstanbul: IstanbulGasFees,
    FkBerlin: BerlinGasFees,
    FkLondon: LondonGasFees,
    FkParis: LondonGasFees,
    FkShanghai: ShanghaiGasFees,
    FkCancun: ShanghaiGasFees,
    FkPrague: ShanghaiGasFees,
  ]

gasCosts(FkFrontier, base, BaseGasCosts)
gasCosts(FkHomestead, homestead, HomesteadGasCosts)
gasCosts(FkTangerine, tangerine, TangerineGasCosts)
gasCosts(FkSpurious, spurious, SpuriousGasCosts)
gasCosts(FkConstantinople, constantinople, ConstantinopleGasCosts)
gasCosts(FkIstanbul, istanbul, IstanbulGasCosts)
gasCosts(FkBerlin, berlin, BerlinGasCosts)
gasCosts(FkLondon, london, LondonGasCosts)
gasCosts(FkShanghai, shanghai, ShanghaiGasCosts)

type
  OpGck* = array[Op, GasCostKind]

func opGck(gc: GasCosts): OpGck {.compileTime.} =
  for op, x in gc:
    result[op] = x.kind

# Map fork to GasCostKind
# used in op_dispatcher.nim
const forkToGck*: array[EVMFork, OpGck] = [
  opGck BaseGasCosts          , # FkFrontier
  opGck HomesteadGasCosts     , # FkHomestead
  opGck TangerineGasCosts     , # kTangerine
  opGck SpuriousGasCosts      , # FkSpurious
  opGck SpuriousGasCosts      , # FkByzantium
  opGck ConstantinopleGasCosts, # FkConstantinople
  opGck SpuriousGasCosts      , # FkPetersburg
  opGck IstanbulGasCosts      , # FkIstanbul
  opGck BerlinGasCosts        , # FkBerlin
  opGck LondonGasCosts        , # FkLondon
  opGck LondonGasCosts        , # FkParis
  opGck ShanghaiGasCosts      , # FkShanghai
  opGck ShanghaiGasCosts      , # FkCancun
  opGck ShanghaiGasCosts      , # FkPrague
  ]

proc forkToSchedule*(fork: EVMFork): GasCosts =
  if fork < FkHomestead:
    BaseGasCosts
  elif fork < FkTangerine:
    HomesteadGasCosts
  elif fork < FkSpurious:
    TangerineGasCosts
  elif fork == FkConstantinople:
    ConstantinopleGasCosts # with EIP-1283
  elif fork < FkIstanbul:
    SpuriousGasCosts
  elif fork < FkBerlin:
    IstanbulGasCosts
  elif fork < FkLondon:
    BerlinGasCosts
  elif fork < FkShanghai:
    LondonGasCosts
  else:
    ShanghaiGasCosts

const
  ## Precompile costs
  GasSHA256* =            GasInt 60
  GasSHA256Word* =        GasInt 12
  GasRIPEMD160* =         GasInt 600
  GasRIPEMD160Word* =     GasInt 120
  GasIdentity* =          GasInt 15
  GasIdentityWord* =      GasInt 3
  GasECRecover* =         GasInt 3000
  GasECAdd* =             GasInt 500
  GasECAddIstanbul* =     GasInt 150
  GasECMul* =             GasInt 40000
  GasECMulIstanbul* =     GasInt 6000
  GasECPairingBase* =     GasInt 100000
  GasECPairingBaseIstanbul* = GasInt 45000
  GasECPairingPerPoint* = GasInt 80000
  GasECPairingPerPointIstanbul* = GasInt 34000
  # The Yellow Paper is special casing the GasQuadDivisor.
  # It is defined in Appendix G with the other GasFeeKind constants
  # instead of Appendix E for precompiled contracts
  GasQuadDivisor*        = 20
  GasQuadDivisorEIP2565* = 3
  # https://eips.ethereum.org/EIPS/eip-2537
  Bls12381G1AddGas*          = GasInt 500
  Bls12381G1MulGas*          = GasInt 12000
  Bls12381G2AddGas*          = GasInt 800
  Bls12381G2MulGas*          = GasInt 45000
  Bls12381PairingBaseGas*    = GasInt 115000
  Bls12381PairingPerPairGas* = GasInt 23000
  Bls12381MapG1Gas*          = GasInt 5500
  Bls12381MapG2Gas*          = GasInt 110000
