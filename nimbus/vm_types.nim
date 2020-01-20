# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, eth/common, eth/trie/db,
  options, json, sets,
  ./vm/[memory, stack, code_stream, evmc_api],
  ./vm/interpreter/[gas_costs, opcode_values, vm_forks], # TODO - will be hidden at a lower layer
  ./db/[db_chain, state_db]

type
  BaseVMState* = ref object of RootObj
    prevHeaders*   : seq[BlockHeader]
    chaindb*       : BaseChainDB
    accessLogs*    : AccessLogs
    blockHeader*   : BlockHeader
    name*          : string
    tracingEnabled*: bool
    tracer*        : TransactionTracer
    logEntries*    : seq[Log]
    receipts*      : seq[Receipt]
    accountDb*     : AccountStateDB
    cumulativeGasUsed*: GasInt
    touchedAccounts*: HashSet[EthAddress]
    suicides*      : HashSet[EthAddress]
    status*        : bool
    txOrigin*      : EthAddress
    txGasPrice*    : GasInt
    gasCosts*      : GasCosts
    fork*          : Fork

  AccessLogs* = ref object
    reads*: Table[string, string]
    writes*: Table[string, string]

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

  Snapshot* = object
    transaction*: DbTransaction
    intermediateRoot*: Hash256

  Computation* = ref object
    # The execution computation
    vmState*:               BaseVMState
    when defined(evmc_enabled):
      host*:                HostContext
    msg*:                   Message
    memory*:                Memory
    stack*:                 Stack
    gasMeter*:              GasMeter
    code*:                  CodeStream
    rawOutput*:             seq[byte]
    returnData*:            seq[byte]
    error*:                 Error
    touchedAccounts*:       HashSet[EthAddress]
    suicides*:              HashSet[EthAddress]
    logEntries*:            seq[Log]
    dbsnapshot*:            Snapshot
    instr*:                 Op
    opIndex*:               int
    # continuation helpers
    nextProc*:              proc() {.gcsafe.}
    memOutLen*:             int
    memOutPos*:             int

  Error* = ref object
    info*:                  string
    burnsGas*:              bool

  GasMeter* = object
    gasRefunded*: GasInt
    startGas*: GasInt
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
    code*:             seq[byte]
    flags*:            MsgFlags
