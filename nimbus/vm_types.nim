# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, eth/common, eth/trie/db,
  options, json, sets,
  ./vm/[memory, stack, code_stream],
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
    status*        : bool

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

  BaseComputation* = ref object of RootObj
    # The execution computation
    vmState*:               BaseVMState
    msg*:                   Message
    memory*:                Memory
    stack*:                 Stack
    gasMeter*:              GasMeter
    code*:                  CodeStream
    children*:              seq[BaseComputation]
    rawOutput*:             seq[byte]
    returnData*:            seq[byte]
    error*:                 Error
    accountsToDelete*:      Table[EthAddress, EthAddress]
    suicides*:              HashSet[EthAddress]
    gasCosts*:              GasCosts # TODO - will be hidden at a lower layer
    forkOverride*:          Option[Fork]
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
    erasesReturnData*:      bool

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
    # A message for VM computation
    # https://github.com/ethereum/evmc/blob/master/include/evmc/evmc.h
    destination*:             EthAddress
    sender*:                  EthAddress
    value*:                   UInt256
    data*:                    seq[byte]
    gas*:                     GasInt
    gasPrice*:                GasInt
    depth*:                   int
    #kind*:                    CallKind
    flags*:                   MsgFlags

    # Not in EVMC API
    # TODO: Done via callback function (v)table in EVMC
    code*:                    seq[byte]

    internalOrigin*:          EthAddress
    internalCodeAddress*:     EthAddress
    internalStorageAddress*:  EthAddress
    contractCreation*:        bool

  MessageOptions* = ref object
    origin*:                  EthAddress
    depth*:                   int
    createAddress*:           EthAddress
    codeAddress*:             EthAddress
    flags*:                   MsgFlags
