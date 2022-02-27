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
  tables, eth/common,
  options, json, sets,
  ./memory, ./stack, ./code_stream, ../forks,
  ./interpreter/[gas_costs, opcode_values],
  # TODO - will be hidden at a lower layer
  ../db/[db_chain, accounts_cache]

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
    chaindb*       : BaseChainDB
    parent*        : BlockHeader
    timestamp*     : EthTime
    gasLimit*      : GasInt
    fee*           : Option[Uint256]
    prevRandao*    : Hash256
    ttdReached*    : bool
    name*          : string
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
    fork*          : Fork
    minerAddress*  : EthAddress

  TracerFlags* {.pure.} = enum
    EnableTracing
    DisableStorage
    DisableMemory
    DisableStack
    DisableState
    DisableStateDiff
    EnableAccount

  TransactionTracer* = object
    trace*: JsonNode
    flags*: set[TracerFlags]
    accounts*: HashSet[EthAddress]
    storageKeys*: seq[HashSet[Uint256]]

  Computation* = ref object
    # The execution computation
    vmState*:               BaseVMState
    when defined(evmc_enabled):
      host*:                HostContext
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
      child*:               ref nimbus_message
      res*:                 nimbus_result
    else:
      parent*, child*:      Computation
    continuation*:          proc() {.gcsafe.}

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
