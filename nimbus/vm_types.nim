# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, eth/common, options,
  ./constants, json, sets,
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
    shouldEraseReturnData*: bool
    accountsToDelete*:      Table[EthAddress, EthAddress]
    opcodes*:               Table[Op, proc(computation: var BaseComputation){.nimcall.}]
    gasCosts*:              GasCosts # TODO - will be hidden at a lower layer
    forkOverride*:          Option[Fork]
    logEntries*:            seq[Log]

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

    # depth = None

    # code = None
    # codeAddress = None

    # createAddress = None

    # logger = logging.getLogger("evm.vm.message.Message")

    destination*:             EthAddress
    sender*:                  EthAddress
    value*:                   UInt256
    data*:                    seq[byte]
    # size_t input_size;
    codeHash*:                UInt256
    create2Salt*:             Uint256
    gas*:                     GasInt
    gasPrice*:                GasInt
    depth*:                   int
    kind*:                    CallKind
    flags*:                   MsgFlags

    # Not in EVMC API

    # TODO: Done via callback function (v)table in EVMC
    code*:                    seq[byte]

    internalOrigin*:          EthAddress
    internalCodeAddress*:     EthAddress
    internalStorageAddress*:  EthAddress

  MessageOptions* = ref object
    origin*:                  EthAddress
    depth*:                   int
    createAddress*:           EthAddress
    codeAddress*:             EthAddress
    flags*:                   MsgFlags
