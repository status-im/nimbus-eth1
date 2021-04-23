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
  ../../../errors,
  ../../memory,
  ../../stack,
  ../forks_list,
  ../op_codes,
  eth/common/eth_types,
  macros,
  sets,
  stint

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

  ChainId* = uint # distinct uint

  ChainConfig* = object
    chainId*: ChainId
    homesteadBlock*: BlockNumber
    daoForkBlock*: BlockNumber
    daoForkSupport*: bool

  AccountsCache* = ref object
    isDirty: bool

  BaseChainDB* = ref object
    pruneTrie*: bool
    config*: ChainConfig

  GasCost* = object
    opaq: int

  GasCosts* = array[Op, GasCost]

  BaseVMState* = ref object of RootObj
    chaindb*       : BaseChainDB
    blockHeader*   : BlockHeader
    logEntries*    : seq[Log]
    accountDb*     : AccountsCache
    touchedAccounts*: HashSet[EthAddress]
    suicides*      : HashSet[EthAddress]
    txOrigin*      : EthAddress
    txGasPrice*    : GasInt
    gasCosts*      : GasCosts
    fork*          : Fork

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
    touchedAccounts*: HashSet[EthAddress]
    suicides*: HashSet[EthAddress]
    logEntries*: seq[Log]

const
  ColdAccountAccessCost* = 2
  WarmStorageReadCost* = 3
  MaxCallDepth*     = 42

# function stubs from state.nim
proc `status=`*(v: BaseVMState; status: bool) = discard
template mutateStateDB*(vmState: BaseVMState, body: untyped) =
  block:
    var db {.inject.} = vmState.accountDb
    body

# function stubs from compu_helper.nim (to satisfy compiler logic)
proc gasCosts*(c: Computation): array[Op,int] = result
proc getBalance*[T](c: Computation, address: T): Uint256 = result
proc accountExists*(c: Computation, address: EthAddress): bool = result

# function stubs from computation.nim (to satisfy compiler logic)
proc execCallOrCreate*(cParam: Computation) = discard
proc refundSelfDestruct*(c: Computation) = discard
func shouldBurnGas*(c: Computation): bool = result
proc getGasRefund*(c: Computation): GasInt = result
proc newComputation*[A,B](v:A, m:B, salt = 0.u256): Computation = new result
proc isSuccess*(c: Computation): bool = result
proc isOriginComputation*(c: Computation): bool = result
proc merge*(c, child: Computation) = discard
template chainTo*(c, d: Computation, e: untyped) =
  c.child = d; c.continuation = proc() = e

# function stubs from accounts_cache.nim (some also match state_db.nim):
func inAccessList*[A,B](ac: A; address: B): bool = false
proc accessList*[A,B](ac: var A, address: B) = discard
proc incNonce*[A,B](ac: var A, address: B) = discard
proc addBalance*[A,B](ac: var A, address: B, delta: UInt256) = discard

# function stubs from gas_meter.nim
proc consumeGas*(gasMeter: var GasMeter;amount: GasInt;reason: string) = discard
proc returnGas*(gasMeter: var GasMeter; amount: GasInt) = discard

# function stubs from gas_costs.nim
type
  GasResult* =
     tuple[gasCost, gasRefund: GasInt]

  GasParams* = object
    case kind*: Op
    of Create:
      cr_currentMemSize*, cr_memOffset*, cr_memLength*: int64
    of Call, CallCode, DelegateCall, StaticCall:
      c_isNewAccount*: bool
      c_contractGas*: Uint256
      c_gasBalance*, c_currentMemSize*, c_memOffset*, c_memLength*: int64
    else:
      discard

proc c_handler*(x: int; y: Uint256, z: GasParams): GasResult = result
proc m_handler*(x: int; curMemSize, memOffset, memLen: int64): int = result
proc forkToSchedule*(fork: Fork): GasCosts = result

# function stubs from config.nim
proc toFork*[T](c: T; number: BlockNumber): Fork = result

# function stubs from transaction.nim
proc intrinsicGas*(tx: Transaction, fork: Fork): GasInt = result

# function stubs from message.nim
proc isCreate*(message: Message): bool = result

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

include
  ./oph_defs,
  ./oph_helpers

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
