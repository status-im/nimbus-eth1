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
  std/tables,
  stint,
  eth/common/[addresses, hashes],
  web3/[eth_api_types, conversions],
  ./rpc_types

type
  TraceCallType* = enum
    call        = "call"
    callcode    = "callcode"
    delegatecall = "delegatecall"
    staticcall  = "staticcall"

  TraceCallAction* = object
    callType*: TraceCallType
    `from`*:   Address
    to*:       Address
    gas*:      Quantity
    input*:    seq[byte]
    value*:    UInt256

  TraceCreateAction* = object
    `from`*:         Address
    gas*:            Quantity
    init*:           seq[byte]
    value*:          UInt256
    creationMethod*: string

  TraceSuicideAction* = object
    address*:       Address
    refundAddress*: Address
    balance*:       UInt256

  TraceRewardAction* = object
    author*:     Address
    rewardType*: string
    value*:      UInt256

  TraceActionKind* = enum
    takCall, takCreate, takSuicide, takReward

  TraceAction* = object
    case kind*: TraceActionKind
    of takCall:    callAction*:    TraceCallAction
    of takCreate:  createAction*:  TraceCreateAction
    of takSuicide: suicideAction*: TraceSuicideAction
    of takReward:  rewardAction*:  TraceRewardAction

  TraceCallResult* = object
    gasUsed*: Quantity
    output*:  seq[byte]

  TraceCreateResult* = object
    gasUsed*: Quantity
    code*:    seq[byte]
    address*: Opt[Address]

  TraceResultKind* = enum
    trkCall, trkCreate

  TraceResult* = object
    case kind*: TraceResultKind
    of trkCall:   callResult*:   TraceCallResult
    of trkCreate: createResult*: TraceCreateResult

  TraceObject* = object
    action*:              TraceAction
    result*:              Opt[TraceResult]
    error*:               Opt[string]
    subtraces*:           int
    traceAddress*:        seq[int]
    `type`*:              string
    blockHash*:           Opt[Hash32]
    blockNumber*:         Opt[uint64]
    transactionHash*:     Opt[Hash32]
    transactionPosition*: Opt[int]

  TraceCallManyResult* = object
    output*:    seq[byte]
    stateDiff*: Opt[StateDiff]
    trace*:     seq[TraceObject]
    vmTrace*:   Opt[VmTrace]

  BalanceDiff* = object
    `from`*: UInt256
    to*:     UInt256

  NonceDiff* = object
    `from`*: uint64
    to*:     uint64

  StorageDiff* = object
    `from`*: UInt256
    to*:     UInt256

  AccountDiff* = object
    balance*: Opt[BalanceDiff]
    nonce*:   Opt[NonceDiff]
    code*:    Opt[tuple[`from`: seq[byte], to: seq[byte]]]
    storage*: Table[UInt256, StorageDiff]
    born*:    bool
    died*:    bool

  StateDiff* = Table[Address, AccountDiff]

  VmTraceOpEx* = object
    mem*:   Opt[tuple[off: int, data: seq[byte]]]
    push*:  seq[UInt256]
    store*: Opt[tuple[key: UInt256, val: UInt256]]
    used*:  GasInt

  VmTraceOp* = object
    pc*:   int
    cost*: GasInt
    ex*:   Opt[VmTraceOpEx]
    sub*:  Opt[VmTrace]

  VmTrace* = object
    code*: seq[byte]
    ops*:  seq[VmTraceOp]

  TraceFilterRequest* = object
    fromBlock*:   Opt[BlockTag]
    toBlock*:     Opt[BlockTag]
    fromAddress*: Opt[seq[Address]]
    toAddress*:   Opt[seq[Address]]
    after*:       Opt[int]
    count*:       Opt[int]

  TraceTypeFlag* = enum
    ttTrace, ttStateDiff, ttVmTrace

TraceFilterRequest.useDefaultSerializationIn EthJson
