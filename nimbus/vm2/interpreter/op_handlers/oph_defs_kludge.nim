# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcodes, Definitions -- Kludge Version
## ==========================================
##

{.warning: "Circular dependency breaker kludge -- no production code".}

import
  ../forks_list,
  ../op_codes,
  ../../memory,
  ../../stack_defs,
  eth/common/eth_types

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

type
  MsgFlags* = enum
    emvcNoFlags  = 0
    emvcStatic   = 1

  CallKind* = enum
    evmcCall         = 0 # CALL
    evmcDelegateCall = 1 # DELEGATECALL
    evmcCallCode     = 2 # CALLCODE
    evmcCreate       = 3 # CREATE
    evmcCreate2      = 4 # CREATE2

  ReadOnlyStateDB* =
    seq[byte]

  GasMeter* = object
    gasRefunded*: GasInt
    gasRemaining*: GasInt

  CodeStream* = ref object
    bytes*: seq[byte]
    pc*: int

  BaseVMState* = ref object of RootObj
    accountDb*: ReadOnlyStateDB

  Message* = ref object
    kind*: CallKind
    depth*: int
    gas*: GasInt
    contractAddress*: EthAddress
    codeAddress*: EthAddress
    sender*: EthAddress
    value*: UInt256
    data*: seq[byte]
    flags*: MsgFlags

  Computation* = ref object
    returnStack*: seq[int]
    output*: seq[byte]
    vmState*: BaseVMState
    gasMeter*: GasMeter
    stack*: Stack
    memory*: Memory
    msg*: Message
    code*: CodeStream
    returnData*: seq[byte]
    fork*: Fork
    parent*, child*: Computation
    continuation*: proc() {.gcsafe.}

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

include
  ./oph_defs

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
