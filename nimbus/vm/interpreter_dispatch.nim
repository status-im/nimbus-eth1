# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, macros,
  chronicles,
  ./interpreter/[opcode_values, opcodes_impl, vm_forks, gas_costs, gas_meter, utils/macros_gen_opcodes],
  ./code_stream,
  ../vm_types, ../errors,
  ./stack, ./computation, terminal # Those are only needed for logging

func invalidInstruction*(computation: var BaseComputation) {.inline.} =
  raise newException(ValueError, "Invalid instruction, received an opcode not implemented in the current fork.")

let FrontierOpDispatch {.compileTime.}: array[Op, NimNode] = block:
  fill_enum_table_holes(Op, newIdentNode"invalidInstruction"):
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
      DelegateCall: newIdentNode "delegateCall",
      # StaticCall: introduced in Byzantium
      # Revert: introduced in Byzantium
      # Invalid: newIdentNode "invalid",
      SelfDestruct: newIdentNode "selfDestruct"
    ]

proc opTableToCaseStmt(opTable: array[Op, NimNode], computation: NimNode): NimNode =

  let instr = genSym(nskVar)
  result = nnkCaseStmt.newTree(instr)

  # Add a branch for each (opcode, proc) pair
  # We dispatch to the next instruction at the end of each branch
  for op, opImpl in opTable.pairs:
    let branchStmt = block:
      if op == Stop:
        quote do: break
      else:
        let asOp = quote do: Op(`op`) # TODO: unfortunately when passing to runtime, ops are transformed into int
        if BaseGasCosts[op].kind == GckFixed:
          quote do:
            `computation`.gasMeter.consumeGas(`computation`.gasCosts[`asOp`].cost, reason = $`asOp`)
            `opImpl`(`computation`)
            `instr` = `computation`.code.next()
        else:
          quote do:
            `opImpl`(`computation`)
            when `asOp` in {Return, Revert, SelfDestruct}:
              break
            else:
              `instr` = `computation`.code.next()

    result.add nnkOfBranch.newTree(
      newIdentNode($op),
      branchStmt
    )

  # Wrap the case statement in while true + computed goto
  result = quote do:
    var `instr` = `computation`.code.next()
    while true:
      {.computedGoto.}
      # TODO lots of macro magic here to unravel, with chronicles...
      # `computation`.logger.log($`computation`.stack & "\n\n", fgGreen)
      `result`

macro genFrontierDispatch(computation: BaseComputation): untyped =
  result = opTableToCaseStmt(FrontierOpDispatch, computation)

proc frontierVM(computation: var BaseComputation) =
  genFrontierDispatch(computation)

proc executeOpcodes*(computation: var BaseComputation) =
  let fork = computation.vmState.blockHeader.blockNumber.toFork
  try:
    case fork
    of FkFrontier: computation.frontierVM()
    else:
      raise newException(ValueError, "not implemented fork: " & $fork)
  except VMError:
    computation.error = Error(info: getCurrentExceptionMsg())
