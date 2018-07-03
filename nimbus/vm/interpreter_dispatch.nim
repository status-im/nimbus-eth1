# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, macros,
  ./interpreter/[opcode_values, opcodes_impl, vm_forks, gas_costs, gas_meter],
  ./code_stream,
  ../vm_types, ../errors

static:
  let
    FrontierOpDispatch: Table[Op, NimNode] = {
      # Stop: special cased
      Add: newIdentNode "addFkFrontier",
      Mul: newIdentNode "mulFkFrontier",
      Sub: newIdentNode "subFkFrontier",
      Div: newIdentNode "divideFkFrontier",
      Sdiv: newIdentNode "sdivFkFrontier",
      Mod: newIdentNode "moduloFkFrontier",
      Smod: newIdentNode "smodFkFrontier",
      Addmod: newIdentNode "addmodFkFrontier",
      Mulmod: newIdentNode "mulmodFkFrontier",
      Exp: newIdentNode "expFkFrontier",
      SignExtend: newIdentNode "signExtendFkFrontier",

      # 10s: Comparison & Bitwise Logic Operations
      Lt: newIdentNode "ltFkFrontier",
      Gt: newIdentNode "gtFkFrontier",
      Slt: newIdentNode "sltFkFrontier",
      Sgt: newIdentNode "sgtFkFrontier",
      Eq: newIdentNode "eqFkFrontier",
      IsZero: newIdentNode "isZeroFkFrontier",
      And: newIdentNode "andOpFkFrontier",
      Or: newIdentNode "orOpFkFrontier",
      Xor: newIdentNode "xorOpFkFrontier",
      Not: newIdentNode "notOpFkFrontier",
      Byte: newIdentNode "byteOpFkFrontier",

      # 20s: SHA3
      Sha3: newIdentNode "sha3FkFrontier",

      # 30s: Environmental Information
      Address: newIdentNode "addressFkFrontier",
      Balance: newIdentNode "balanceFkFrontier",
      Origin: newIdentNode "originFkFrontier",
      Caller: newIdentNode "callerFkFrontier",
      CallValue: newIdentNode "callValueFkFrontier",
      CallDataLoad: newIdentNode "callDataLoadFkFrontier",
      CallDataSize: newIdentNode "callDataSizeFkFrontier",
      CallDataCopy: newIdentNode "callDataCopyFkFrontier",
      CodeSize: newIdentNode "codeSizeFkFrontier",
      CodeCopy: newIdentNode "codeCopyFkFrontier",
      GasPrice: newIdentNode "gasPriceFkFrontier",
      ExtCodeSize: newIdentNode "extCodeSizeFkFrontier",
      ExtCodeCopy: newIdentNode "extCodeCopyFkFrontier",
      # ReturnDataSize: introduced in Byzantium
      # ReturnDataCopy: introduced in Byzantium

      # 40s: Block Information
      Blockhash: newIdentNode "blockhashFkFrontier",
      Coinbase: newIdentNode "coinbaseFkFrontier",
      Timestamp: newIdentNode "timestampFkFrontier",
      Number: newIdentNode "blockNumberFkFrontier",
      Difficulty: newIdentNode "difficultyFkFrontier",
      GasLimit: newIdentNode "gasLimitFkFrontier",

      # 50s: Stack, Memory, Storage and Flow Operations
      Pop: newIdentNode "popFkFrontier",
      Mload: newIdentNode "mloadFkFrontier",
      Mstore: newIdentNode "mstoreFkFrontier",
      Mstore8: newIdentNode "mstore8FkFrontier",
      Sload: newIdentNode "sloadFkFrontier",
      Sstore: newIdentNode "sstoreFkFrontier",
      Jump: newIdentNode "jumpFkFrontier",
      JumpI: newIdentNode "jumpIFkFrontier",
      Pc: newIdentNode "pcFkFrontier",
      Msize: newIdentNode "msizeFkFrontier",
      Gas: newIdentNode "gasFkFrontier",
      JumpDest: newIdentNode "jumpDestFkFrontier",

      # 60s & 70s: Push Operations.
      Push1: newIdentNode "push1FkFrontier",
      Push2: newIdentNode "push2FkFrontier",
      Push3: newIdentNode "push3FkFrontier",
      Push4: newIdentNode "push4FkFrontier",
      Push5: newIdentNode "push5FkFrontier",
      Push6: newIdentNode "push6FkFrontier",
      Push7: newIdentNode "push7FkFrontier",
      Push8: newIdentNode "push8FkFrontier",
      Push9: newIdentNode "push9FkFrontier",
      Push10: newIdentNode "push10FkFrontier",
      Push11: newIdentNode "push11FkFrontier",
      Push12: newIdentNode "push12FkFrontier",
      Push13: newIdentNode "push13FkFrontier",
      Push14: newIdentNode "push14FkFrontier",
      Push15: newIdentNode "push15FkFrontier",
      Push16: newIdentNode "push16FkFrontier",
      Push17: newIdentNode "push17FkFrontier",
      Push18: newIdentNode "push18FkFrontier",
      Push19: newIdentNode "push19FkFrontier",
      Push20: newIdentNode "push20FkFrontier",
      Push21: newIdentNode "push21FkFrontier",
      Push22: newIdentNode "push22FkFrontier",
      Push23: newIdentNode "push23FkFrontier",
      Push24: newIdentNode "push24FkFrontier",
      Push25: newIdentNode "push25FkFrontier",
      Push26: newIdentNode "push26FkFrontier",
      Push27: newIdentNode "push27FkFrontier",
      Push28: newIdentNode "push28FkFrontier",
      Push29: newIdentNode "push29FkFrontier",
      Push30: newIdentNode "push30FkFrontier",
      Push31: newIdentNode "push31FkFrontier",
      Push32: newIdentNode "push32FkFrontier",

      # 80s: Duplication Operations
      Dup1: newIdentNode "dup1FkFrontier",
      Dup2: newIdentNode "dup2FkFrontier",
      Dup3: newIdentNode "dup3FkFrontier",
      Dup4: newIdentNode "dup4FkFrontier",
      Dup5: newIdentNode "dup5FkFrontier",
      Dup6: newIdentNode "dup6FkFrontier",
      Dup7: newIdentNode "dup7FkFrontier",
      Dup8: newIdentNode "dup8FkFrontier",
      Dup9: newIdentNode "dup9FkFrontier",
      Dup10: newIdentNode "dup10FkFrontier",
      Dup11: newIdentNode "dup11FkFrontier",
      Dup12: newIdentNode "dup12FkFrontier",
      Dup13: newIdentNode "dup13FkFrontier",
      Dup14: newIdentNode "dup14FkFrontier",
      Dup15: newIdentNode "dup15FkFrontier",
      Dup16: newIdentNode "dup16FkFrontier",

      # 90s: Exchange Operations
      Swap1: newIdentNode "swap1FkFrontier",
      Swap2: newIdentNode "swap2FkFrontier",
      Swap3: newIdentNode "swap3FkFrontier",
      Swap4: newIdentNode "swap4FkFrontier",
      Swap5: newIdentNode "swap5FkFrontier",
      Swap6: newIdentNode "swap6FkFrontier",
      Swap7: newIdentNode "swap7FkFrontier",
      Swap8: newIdentNode "swap8FkFrontier",
      Swap9: newIdentNode "swap9FkFrontier",
      Swap10: newIdentNode "swap10FkFrontier",
      Swap11: newIdentNode "swap11FkFrontier",
      Swap12: newIdentNode "swap12FkFrontier",
      Swap13: newIdentNode "swap13FkFrontier",
      Swap14: newIdentNode "swap14FkFrontier",
      Swap15: newIdentNode "swap15FkFrontier",
      Swap16: newIdentNode "swap16FkFrontier",

      # a0s: Logging Operations
      Log0: newIdentNode "log0FkFrontier",
      Log1: newIdentNode "log1FkFrontier",
      Log2: newIdentNode "log2FkFrontier",
      Log3: newIdentNode "log3FkFrontier",
      Log4: newIdentNode "log4FkFrontier",

      # f0s: System operations
      Create: newIdentNode "createFkFrontier",
      Call: newIdentNode "callFkFrontier",
      CallCode: newIdentNode "callCodeFkFrontier",
      Return: newIdentNode "returnOpFkFrontier",
      DelegateCall: newIdentNode "delegateCallFkFrontier",
      # StaticCall: introduced in Byzantium
      # Revert: introduced in Byzantium
      # Invalid: newIdentNode "invalidFkFrontier",
      SelfDestruct: newIdentNode "selfDestructFkFrontier",
    }.toTable()

proc opTableToCaseStmt(opTable: Table[Op, NimNode], computation: NimNode): NimNode =

  let instr = genSym(nskVar)
  result = nnkCaseStmt.newTree(instr)

  # Handle STOP
  result.add nnkOfBranch.newTree(
    # of STOP: break
    newIdentNode("Stop"),
    nnkStmtList.newTree(
      nnkBreakStmt.newTree(
        newEmptyNode()
      )
    )
  )

  # Add a branch for each (opcode, proc) pair
  # We dispatch to the next instruction at the end of each branch
  for op, opImpl in opTable.pairs:
    let branchStmt = block:
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

  # Everything else is an error
  result.add nnkElse.newTree(
    quote do: raise newException(ValueError, "Unsupported opcode: " & $`instr`)
  )

  # Wrap the case statement in while true + computed goto
  result = quote do:
    var `instr` = `computation`.code.next()
    while true:
      # {.computedGoto.} # TODO: case statement must be exhaustive
      `result`

macro genFrontierDispatch(computation: BaseComputation): untyped =
  result = opTableToCaseStmt(FrontierOpDispatch, computation)

proc frontierVM(computation: var BaseComputation) =
  genFrontierDispatch(computation)

proc executeOpcodes*(computation: var BaseComputation) =

  let fork = computation.vmState.blockHeader.blockNumber.toFork

  try: # TODO logging similar to the "inComputation" template
    case fork
    of FkFrontier: computation.frontierVM()
    else:
      raise newException(ValueError, "not implemented fork: " & $fork)
  except VMError:
    computation.error = Error(info: getCurrentExceptionMsg())
