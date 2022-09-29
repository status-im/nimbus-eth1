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
  chronos,
  ./stack,  ./memory, ./code_stream, ../forks,
  ./interpreter/[gas_costs, op_codes],
  # TODO - will be hidden at a lower layer
  ../db/[db_chain, accounts_cache]

type
  VMFlag* = enum
    ExecutionOK
    GenerateWitness
    ClearCache

  BaseVMState* = ref object of RootObj
    prevHeaders*   : seq[BlockHeader]
    chainDB*       : BaseChainDB
    parent*        : BlockHeader
    timestamp*     : EthTime
    gasLimit*      : GasInt
    fee*           : Option[UInt256]
    prevRandao*    : Hash256
    blockDifficulty*: UInt256
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
    storageKeys*: seq[HashSet[UInt256]]

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
    parent*, child*:        Computation
    continuation*:          proc(): Future[void] {.gcsafe.}

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

# AARDVARK - This is very obviously not the right place for this;
# that's why I'm putting it here. This must already exist elsewhere.
# Either find the existing one, or create it in the chronos
# library, or learn why it's a bad idea.
# -- Adam
proc newCompletedVoidFuture*(): Future[void] =
  let f = newFuture[void]("vm2/types/newCompletedVoidFuture()")
  f.complete()
  f
