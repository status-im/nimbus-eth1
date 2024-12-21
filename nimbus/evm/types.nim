# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  "."/[stack, memory, code_stream, evm_errors],
  ./interpreter/[gas_costs, op_codes],
  ../db/ledger,
  ../common/[common, evmforks]

export stack, memory

# this import not guarded by `when defined(evmc_enabled)`
# because we want to use evmc types such as evmc_call_kind
# and evmc_flags
import
  evmc/evmc

export evmc

{.push raises: [].}

when defined(evmc_enabled):
  import
    ./evmc_api

# Select between small-stack recursion and no recursion.  Both are good, fast,
# low resource using methods.  Keep both here because true EVMC API requires
# the small-stack method, but Chronos `async` is better without recursion.
const vm_use_recursion* = defined(evmc_enabled)

type
  VMFlag* = enum
    ExecutionOK
    CollectWitnessData

  BlockContext* = object
    timestamp*        : EthTime
    gasLimit*         : GasInt
    baseFeePerGas*    : Opt[UInt256]
    prevRandao*       : Bytes32
    difficulty*       : UInt256
    coinbase*         : Address
    excessBlobGas*    : uint64
    parentHash*       : Hash32

  TxContext* = object
    origin*         : Address
    gasPrice*       : GasInt
    versionedHashes*: seq[VersionedHash]
    blobBaseFee*    : UInt256

  BaseVMState* = ref object of RootObj
    com*              : CommonRef
    ledger*           : LedgerRef
    gasPool*          : GasInt
    parent*           : Header
    blockCtx*         : BlockContext
    txCtx*            : TxContext
    flags*            : set[VMFlag]
    fork*             : EVMFork
    tracer*           : TracerRef
    receipts*         : seq[Receipt]
    cumulativeGasUsed*: GasInt
    gasCosts*         : GasCosts
    blobGasUsed*      : uint64
    allLogs*          : seq[Log] # EIP-6110
    gasRefunded*      : int64    # Global gasRefunded counter

  Computation* = ref object
    # The execution computation
    vmState*:               BaseVMState
    msg*:                   Message
    memory*:                EvmMemory
    stack*:                 EvmStack
    gasMeter*:              GasMeter
    code*:                  CodeStream
    output*:                seq[byte]
    returnData*:            seq[byte]
    error*:                 Error
    savePoint*:             LedgerSpRef
    instr*:                 Op
    opIndex*:               int
    when defined(evmc_enabled):
      host*:                HostContext
      child*:               ref nimbus_message
      res*:                 nimbus_result
    else:
      parent*, child*:      Computation
    continuation*:          proc(): EvmResultVoid {.gcsafe, raises: [].}
    keepStack*:             bool
    finalStack*:            seq[UInt256]

  Error* = ref object
    evmcStatus*: evmc_status_code
    info*      : string
    burnsGas*  : bool

  GasMeter* = object
    gasRefunded*: int64
    gasRemaining*: GasInt

  CallKind* = evmc_call_kind

  MsgFlags* = evmc_flags

  Message* = ref object
    kind*:             CallKind
    depth*:            int
    gas*:              GasInt
    sender*:           Address
    contractAddress*:  Address
    codeAddress*:      Address
    value*:            UInt256
    data*:             seq[byte]
    flags*:            MsgFlags

  TracerFlags* {.pure.} = enum
    DisableStorage
    DisableMemory
    DisableStack
    DisableState
    DisableStateDiff
    EnableAccount
    DisableReturnData

  TracerRef* = ref object of RootObj
    flags*: set[TracerFlags]

# Transaction level
# This is called once fo each transaction
method captureTxStart*(ctx: TracerRef, gasLimit: GasInt) {.base, gcsafe.} =
  discard

method captureTxEnd*(ctx: TracerRef, restGas: GasInt) {.base, gcsafe.} =
  discard

# Top call frame
method captureStart*(ctx: TracerRef, comp: Computation,
                     sender: Address, to: Address,
                     create: bool, input: openArray[byte],
                     gasLimit: GasInt, value: UInt256) {.base, gcsafe.} =
  discard

method captureEnd*(ctx: TracerRef, comp: Computation, output: openArray[byte],
                   gasUsed: GasInt, error: Opt[string]) {.base, gcsafe.} =
  discard

# Rest of call frames
method captureEnter*(ctx: TracerRef, comp: Computation, op: Op,
                     sender: Address, to: Address,
                     input: openArray[byte], gasLimit: GasInt,
                     value: UInt256) {.base, gcsafe.} =
  discard

method captureExit*(ctx: TracerRef, comp: Computation, output: openArray[byte],
                    gasUsed: GasInt, error: Opt[string]) {.base, gcsafe.} =
  discard

# Opcode level
method captureOpStart*(ctx: TracerRef, comp: Computation,
                       fixed: bool, pc: int, op: Op, gas: GasInt,
                       depth: int): int {.base, gcsafe.} =
  discard

method captureGasCost*(ctx: TracerRef, comp: Computation,
                       fixed: bool, op: Op, gasCost: GasInt,
                       gasRemaining: GasInt, depth: int) {.base, gcsafe.} =
  discard

method captureOpEnd*(ctx: TracerRef, comp: Computation,
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: int64,
                     rData: openArray[byte],
                     depth: int, opIndex: int) {.base, gcsafe.} =
  discard

method captureFault*(ctx: TracerRef, comp: Computation,
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: int64,
                     rData: openArray[byte],
                     depth: int, error: Opt[string]) {.base, gcsafe.} =
  discard

# Called at the start of EVM interpreter loop
method capturePrepare*(ctx: TracerRef, comp: Computation, depth: int) {.base, gcsafe.} =
  discard
