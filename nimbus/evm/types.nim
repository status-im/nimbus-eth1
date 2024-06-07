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
    GenerateWitness

  BlockContext* = object
    timestamp*        : EthTime
    gasLimit*         : GasInt
    fee*              : Option[UInt256]
    prevRandao*       : Hash256
    difficulty*       : UInt256
    coinbase*         : EthAddress
    excessBlobGas*    : uint64

  TxContext* = object
    origin*         : EthAddress
    gasPrice*       : GasInt
    versionedHashes*: VersionedHashes
    blobBaseFee*    : UInt256

  BaseVMState* = ref object of RootObj
    com*              : CommonRef
    stateDB*          : LedgerRef
    gasPool*          : GasInt
    parent*           : BlockHeader
    blockCtx*         : BlockContext
    txCtx*            : TxContext
    flags*            : set[VMFlag]
    fork*             : EVMFork
    tracer*           : TracerRef
    receipts*         : seq[Receipt]
    cumulativeGasUsed*: GasInt
    gasCosts*         : GasCosts

  Computation* = ref object
    # The execution computation
    vmState*:               BaseVMState
    msg*:                   Message
    memory*:                EvmMemoryRef
    stack*:                 EvmStackRef
    returnStack*:           seq[int]
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
    sysCall*:               bool

  Error* = ref object
    evmcStatus*: evmc_status_code
    info*      : string
    burnsGas*  : bool

  GasMeter* = object
    gasRefunded*: GasInt
    gasRemaining*: GasInt

  CallKind* = evmc_call_kind

  MsgFlags* = evmc_flags

  Message* = ref object
    kind*:             CallKind
    depth*:            int
    gas*:              GasInt
    sender*:           EthAddress
    contractAddress*:  EthAddress
    codeAddress*:      EthAddress
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

  StructLog* = object
    pc*         : int
    op*         : Op
    gas*        : GasInt
    gasCost*    : GasInt
    memory*     : seq[byte]
    memSize*    : int
    stack*      : seq[UInt256]
    returnData* : seq[byte]
    storage*    : Table[UInt256, UInt256]
    depth*      : int
    refund*     : GasInt
    opName*     : string
    error*      : string

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
                     sender: EthAddress, to: EthAddress,
                     create: bool, input: openArray[byte],
                     gasLimit: GasInt, value: UInt256) {.base, gcsafe.} =
  discard

method captureEnd*(ctx: TracerRef, comp: Computation, output: openArray[byte],
                   gasUsed: GasInt, error: Option[string]) {.base, gcsafe.} =
  discard

# Rest of call frames
method captureEnter*(ctx: TracerRef, comp: Computation, op: Op,
                     sender: EthAddress, to: EthAddress,
                     input: openArray[byte], gasLimit: GasInt,
                     value: UInt256) {.base, gcsafe.} =
  discard

method captureExit*(ctx: TracerRef, comp: Computation, output: openArray[byte],
                    gasUsed: GasInt, error: Option[string]) {.base, gcsafe.} =
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
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: GasInt,
                     rData: openArray[byte],
                     depth: int, opIndex: int) {.base, gcsafe.} =
  discard

method captureFault*(ctx: TracerRef, comp: Computation,
                     fixed: bool, pc: int, op: Op, gas: GasInt, refund: GasInt,
                     rData: openArray[byte],
                     depth: int, error: Option[string]) {.base, gcsafe.} =
  discard

# Called at the start of EVM interpreter loop
method capturePrepare*(ctx: TracerRef, comp: Computation, depth: int) {.base, gcsafe.} =
  discard
