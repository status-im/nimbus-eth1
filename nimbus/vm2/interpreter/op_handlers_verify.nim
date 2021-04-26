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
  ./forks_list,
  ./op_codes,
  ./op_handlers,
  ./utils/macros_gen_opcodes,
  macros,
  strformat

# ------------------------------------------------------------------------------
# The follwong is mostly original code excerpt from interpreter_dispatch.nim
# This module has no production use, rather it is used to verify the
# implementation in interpreter_dispatch_tables.nim.
# ------------------------------------------------------------------------------

let FrontierOpDispatch {.compileTime.}: array[Op, NimNode] = block:
  fill_enum_table_holes(Op, newIdentNode("invalidInstruction")):
    [
      Stop: newIdentNode "toBeReplacedByBreak",
      Add: newIdentNode "add",
      Mul: newIdentNode "mul",
      Sub: newIdentNode "sub",
      Div: newIdentNode "divide",
      Sdiv: newIdentNode "sdiv",
      Mod: newIdentNode "modulo",
      Smod: newIdentNode "smod",
      Addmod: newIdentNode "addmod",
      Mulmod: newIdentNode "mulmod",
      Exp: newIdentNode "exp",
      SignExtend: newIdentNode "signExtend",

      # 10s: Comparison & Bitwise Logic Operations
      Lt: newIdentNode "lt",
      Gt: newIdentNode "gt",
      Slt: newIdentNode "slt",
      Sgt: newIdentNode "sgt",
      Eq: newIdentNode "eq",
      IsZero: newIdentNode "isZero",
      And: newIdentNode "andOp",
      Or: newIdentNode "orOp",
      Xor: newIdentNode "xorOp",
      Not: newIdentNode "notOp",
      Byte: newIdentNode "byteOp",

      # 20s: SHA3
      Sha3: newIdentNode "sha3",

      # 30s: Environmental Information
      Address: newIdentNode "address",
      Balance: newIdentNode "balance",
      Origin: newIdentNode "origin",
      Caller: newIdentNode "caller",
      CallValue: newIdentNode "callValue",
      CallDataLoad: newIdentNode "callDataLoad",
      CallDataSize: newIdentNode "callDataSize",
      CallDataCopy: newIdentNode "callDataCopy",
      CodeSize: newIdentNode "codeSize",
      CodeCopy: newIdentNode "codeCopy",
      GasPrice: newIdentNode "gasPrice",
      ExtCodeSize: newIdentNode "extCodeSize",
      ExtCodeCopy: newIdentNode "extCodeCopy",
      # ReturnDataSize: introduced in Byzantium
      # ReturnDataCopy: introduced in Byzantium

      # 40s: Block Information
      Blockhash: newIdentNode "blockhash",
      Coinbase: newIdentNode "coinbase",
      Timestamp: newIdentNode "timestamp",
      Number: newIdentNode "blockNumber",
      Difficulty: newIdentNode "difficulty",
      GasLimit: newIdentNode "gasLimit",

      # 50s: Stack, Memory, Storage and Flow Operations
      Pop: newIdentNode "pop",
      Mload: newIdentNode "mload",
      Mstore: newIdentNode "mstore",
      Mstore8: newIdentNode "mstore8",
      Sload: newIdentNode "sload",
      Sstore: newIdentNode "sstore",
      Jump: newIdentNode "jump",
      JumpI: newIdentNode "jumpI",
      Pc: newIdentNode "pc",
      Msize: newIdentNode "msize",
      Gas: newIdentNode "gas",
      JumpDest: newIdentNode "jumpDest",

      # 60s & 70s: Push Operations.
      Push1: newIdentNode "push1",
      Push2: newIdentNode "push2",
      Push3: newIdentNode "push3",
      Push4: newIdentNode "push4",
      Push5: newIdentNode "push5",
      Push6: newIdentNode "push6",
      Push7: newIdentNode "push7",
      Push8: newIdentNode "push8",
      Push9: newIdentNode "push9",
      Push10: newIdentNode "push10",
      Push11: newIdentNode "push11",
      Push12: newIdentNode "push12",
      Push13: newIdentNode "push13",
      Push14: newIdentNode "push14",
      Push15: newIdentNode "push15",
      Push16: newIdentNode "push16",
      Push17: newIdentNode "push17",
      Push18: newIdentNode "push18",
      Push19: newIdentNode "push19",
      Push20: newIdentNode "push20",
      Push21: newIdentNode "push21",
      Push22: newIdentNode "push22",
      Push23: newIdentNode "push23",
      Push24: newIdentNode "push24",
      Push25: newIdentNode "push25",
      Push26: newIdentNode "push26",
      Push27: newIdentNode "push27",
      Push28: newIdentNode "push28",
      Push29: newIdentNode "push29",
      Push30: newIdentNode "push30",
      Push31: newIdentNode "push31",
      Push32: newIdentNode "push32",

      # 80s: Duplication Operations
      Dup1: newIdentNode "dup1",
      Dup2: newIdentNode "dup2",
      Dup3: newIdentNode "dup3",
      Dup4: newIdentNode "dup4",
      Dup5: newIdentNode "dup5",
      Dup6: newIdentNode "dup6",
      Dup7: newIdentNode "dup7",
      Dup8: newIdentNode "dup8",
      Dup9: newIdentNode "dup9",
      Dup10: newIdentNode "dup10",
      Dup11: newIdentNode "dup11",
      Dup12: newIdentNode "dup12",
      Dup13: newIdentNode "dup13",
      Dup14: newIdentNode "dup14",
      Dup15: newIdentNode "dup15",
      Dup16: newIdentNode "dup16",

      # 90s: Exchange Operations
      Swap1: newIdentNode "swap1",
      Swap2: newIdentNode "swap2",
      Swap3: newIdentNode "swap3",
      Swap4: newIdentNode "swap4",
      Swap5: newIdentNode "swap5",
      Swap6: newIdentNode "swap6",
      Swap7: newIdentNode "swap7",
      Swap8: newIdentNode "swap8",
      Swap9: newIdentNode "swap9",
      Swap10: newIdentNode "swap10",
      Swap11: newIdentNode "swap11",
      Swap12: newIdentNode "swap12",
      Swap13: newIdentNode "swap13",
      Swap14: newIdentNode "swap14",
      Swap15: newIdentNode "swap15",
      Swap16: newIdentNode "swap16",

      # a0s: Logging Operations
      Log0: newIdentNode "log0",
      Log1: newIdentNode "log1",
      Log2: newIdentNode "log2",
      Log3: newIdentNode "log3",
      Log4: newIdentNode "log4",

      # f0s: System operations
      Create: newIdentNode "create",
      Call: newIdentNode "call",
      CallCode: newIdentNode "callCode",
      Return: newIdentNode "returnOp",
      # StaticCall: introduced in Byzantium
      # Revert: introduced in Byzantium
      # Invalid: newIdentNode "invalid",
      SelfDestruct: newIdentNode "selfDestruct"
    ]

proc genHomesteadJumpTable(ops: array[Op, NimNode]): array[Op, NimNode] {.compileTime.} =
  result = ops
  result[DelegateCall] = newIdentNode "delegateCall"

let HomesteadOpDispatch {.compileTime.}: array[Op, NimNode] = genHomesteadJumpTable(FrontierOpDispatch)

proc genTangerineJumpTable(ops: array[Op, NimNode]): array[Op, NimNode] {.compileTime.} =
  result = ops
  result[SelfDestruct] = newIdentNode "selfDestructEIP150"

let TangerineOpDispatch {.compileTime.}: array[Op, NimNode] = genTangerineJumpTable(HomesteadOpDispatch)

proc genSpuriousJumpTable(ops: array[Op, NimNode]): array[Op, NimNode] {.compileTime.} =
  result = ops
  result[SelfDestruct] = newIdentNode "selfDestructEIP161"

let SpuriousOpDispatch {.compileTime.}: array[Op, NimNode] = genSpuriousJumpTable(TangerineOpDispatch)

proc genByzantiumJumpTable(ops: array[Op, NimNode]): array[Op, NimNode] {.compileTime.} =
  result = ops
  result[Revert] = newIdentNode "revert"
  result[ReturnDataSize] = newIdentNode "returnDataSize"
  result[ReturnDataCopy] = newIdentNode "returnDataCopy"
  result[StaticCall] = newIdentNode"staticCall"

let ByzantiumOpDispatch {.compileTime.}: array[Op, NimNode] = genByzantiumJumpTable(SpuriousOpDispatch)

proc genConstantinopleJumpTable(ops: array[Op, NimNode]): array[Op, NimNode] {.compileTime.} =
  result = ops
  result[Shl] = newIdentNode "shlOp"
  result[Shr] = newIdentNode "shrOp"
  result[Sar] = newIdentNode "sarOp"
  result[ExtCodeHash] = newIdentNode "extCodeHash"
  result[Create2] = newIdentNode "create2"
  result[SStore] = newIdentNode "sstoreEIP1283"

let ConstantinopleOpDispatch {.compileTime.}: array[Op, NimNode] = genConstantinopleJumpTable(ByzantiumOpDispatch)

proc genPetersburgJumpTable(ops: array[Op, NimNode]): array[Op, NimNode] {.compileTime.} =
  result = ops
  result[SStore] = newIdentNode "sstore" # disable EIP-1283

let PetersburgOpDispatch {.compileTime.}: array[Op, NimNode] = genPetersburgJumpTable(ConstantinopleOpDispatch)

proc genIstanbulJumpTable(ops: array[Op, NimNode]): array[Op, NimNode] {.compileTime.} =
  result = ops
  result[ChainId] = newIdentNode "chainId"
  result[SelfBalance] = newIdentNode "selfBalance"
  result[SStore] = newIdentNode "sstoreEIP2200"

let IstanbulOpDispatch {.compileTime.}: array[Op, NimNode] = genIstanbulJumpTable(PetersburgOpDispatch)

proc genBerlinJumpTable(ops: array[Op, NimNode]): array[Op, NimNode] {.compileTime.} =
  result = ops
  result[BeginSub] = newIdentNode "beginSub"
  result[ReturnSub] = newIdentNode "returnSub"
  result[JumpSub] = newIdentNode "jumpSub"

  result[Balance] = newIdentNode "balanceEIP2929"
  result[ExtCodeHash] = newIdentNode "extCodeHashEIP2929"
  result[ExtCodeSize] = newIdentNode "extCodeSizeEIP2929"
  result[ExtCodeCopy] = newIdentNode "extCodeCopyEIP2929"
  result[SelfDestruct] = newIdentNode "selfDestructEIP2929"
  result[SLoad] = newIdentNode "sloadEIP2929"
  result[SStore] = newIdentNode "sstoreEIP2929"

let BerlinOpDispatch {.compileTime.}: array[Op, NimNode] = genBerlinJumpTable(IstanbulOpDispatch)

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

static:
  let OrigAllOpDispatch = block:
    var rc: array[Fork, array[Op, NimNode]]
    rc[FkFrontier]       = FrontierOpDispatch
    rc[FkHomestead]      = HomesteadOpDispatch
    rc[FkTangerine]      = TangerineOpDispatch
    rc[FkSpurious]       = SpuriousOpDispatch
    rc[FkByzantium]      = ByzantiumOpDispatch
    rc[FkConstantinople] = ConstantinopleOpDispatch
    rc[FkPetersburg]     = PetersburgOpDispatch
    rc[FkIstanbul]       = IstanbulOpDispatch
    rc[FkBerlin]         = BerlinOpDispatch
    rc

  echo "*** verifying op handler tables will take a while ..."

  var vm2OpHandlerErrors = 0
  for fork in Fork:
    for op in Op:

      var
        vm2OpName = vm2OpHandlers[fork][op].name
        origName = OrigAllOpDispatch[fork][op].strVal

      if origName != vm2OpName:
        vm2OpHandlerErrors.inc
        echo "*** problem: vm2OpHandlers",
          & "[{fork}][{op}].name is \"{vm2OpName}\" expected \"{origName}\""

  doAssert vm2OpHandlerErrors == 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
