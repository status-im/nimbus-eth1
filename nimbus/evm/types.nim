# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, sets],
  chronos,
  json_rpc/rpcclient,
  "."/[stack, memory, code_stream],
  ./interpreter/[gas_costs, op_codes],
  ../db/accounts_cache,
  ../common/[common, evmforks]

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
    ClearCache

  BaseVMState* = ref object of RootObj
    prevHeaders*   : seq[BlockHeader]
    com*           : CommonRef
    parent*        : BlockHeader
    timestamp*     : EthTime
    gasLimit*      : GasInt
    fee*           : Option[UInt256]
    prevRandao*    : Hash256
    blockDifficulty*: UInt256
    flags*         : set[VMFlag]
    tracer*        : TransactionTracer
    logEntries*    : seq[Log]
    receipts*      : seq[Receipt]
    stateDB*       : AccountsCache
    cumulativeGasUsed*: GasInt
    touchedAccounts*: HashSet[EthAddress]
    selfDestructs* : HashSet[EthAddress]
    txOrigin*      : EthAddress
    txGasPrice*    : GasInt
    gasCosts*      : GasCosts
    fork*          : EVMFork
    minerAddress*  : EthAddress
    asyncFactory*  : AsyncOperationFactory

  TracerFlags* {.pure.} = enum
    EnableTracing
    DisableStorage
    DisableMemory
    DisableStack
    DisableState
    DisableStateDiff
    EnableAccount
    DisableReturnData
    GethCompatibility

  TransactionTracer* = object
    trace*: JsonNode
    flags*: set[TracerFlags]
    accounts*: HashSet[EthAddress]
    storageKeys*: seq[HashSet[UInt256]]
    gasUsed*: GasInt

  Computation* = ref object
    # The execution computation
    vmState*:               BaseVMState
    msg*:                   Message
    memory*:                Memory
    stack*:                 Stack
    returnStack*:           seq[int]
    gasMeter*:              GasMeter
    code*:                  CodeStream
    output*:                seq[byte]
    returnData*:            seq[byte]
    error*:                 Error
    touchedAccounts*:       HashSet[EthAddress]
    selfDestructs*:         HashSet[EthAddress]
    logEntries*:            seq[Log]
    savePoint*:             SavePoint
    instr*:                 Op
    opIndex*:               int
    when defined(evmc_enabled):
      host*:                HostContext
      child*:               ref nimbus_message
      res*:                 nimbus_result
    else:
      parent*, child*:      Computation
    pendingAsyncOperation*: Future[void]
    continuation*:          proc() {.gcsafe, raises: [CatchableError].}

  Error* = ref object
    info*:                  string
    burnsGas*:              bool

  GasMeter* = object
    gasRefunded*: GasInt
    gasRemaining*: GasInt

  CallKind* = enum
    evmcCall         = 0, # CALL
    evmcDelegateCall = 1, # DELEGATECALL
    evmcCallCode     = 2, # CALLCODE
    evmcCreate       = 3, # CREATE
    evmcCreate2      = 4  # CREATE2

  MsgFlags* = enum
    emvcNoFlags  = 0
    emvcStatic   = 1

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

  LazyDataSource* = ref object of RootObj
    ifNecessaryGetStorage*:
      proc(c: Computation, slot: UInt256): Future[void]
        {.gcsafe, raises: [CatchableError].}

  AsyncOperationFactory* = ref object of RootObj
    lazyDataSource*: LazyDataSource
