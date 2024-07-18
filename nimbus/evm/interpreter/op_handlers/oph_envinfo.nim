# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Environmental Information
## ==============================================
##

{.push raises: [].}

import
  ../../evm_errors,
  ../../code_stream,
  ../../computation,
  ../../memory,
  ../../stack,
  ../gas_costs,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  ./oph_helpers,
  eth/common,
  stew/assign2,
  stint

when not defined(evmc_enabled):
  import ../../state

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

proc addressOp (k: var VmCtx): EvmResultVoid =
  ## 0x30, Get address of currently executing account.
  k.cpt.stack.push k.cpt.msg.contractAddress

# ------------------

proc balanceOp (k: var VmCtx): EvmResultVoid =
  ## 0x31, Get balance of the given account.
  ? k.cpt.stack.lsCheck(1)
  let
    cpt = k.cpt
    address = cpt.stack.lsPeekAddress(^1)
  cpt.stack.lsTop cpt.getBalance(address)
  ok()

proc balanceEIP2929Op (k: var VmCtx): EvmResultVoid =
  ## 0x31, EIP292: Get balance of the given account for Berlin and later
  ? k.cpt.stack.lsCheck(1)
  let
    cpt = k.cpt
    address = cpt.stack.lsPeekAddress(^1)
    gasCost = cpt.gasEip2929AccountCheck(address)

  ? cpt.opcodeGasCost(Balance, gasCost, reason = "Balance EIP2929")
  cpt.stack.lsTop cpt.getBalance(address)
  ok()

# ------------------

proc originOp (k: var VmCtx): EvmResultVoid =
  ## 0x32, Get execution origination address.
  k.cpt.stack.push k.cpt.getOrigin()

proc callerOp (k: var VmCtx): EvmResultVoid =
  ## 0x33, Get caller address.
  k.cpt.stack.push k.cpt.msg.sender

proc callValueOp (k: var VmCtx): EvmResultVoid =
  ## 0x34, Get deposited value by the instruction/transaction
  ##       responsible for this execution
  k.cpt.stack.push k.cpt.msg.value

proc callDataLoadOp (k: var VmCtx): EvmResultVoid =
  ## 0x35, Get input data of current environment
  ? k.cpt.stack.lsCheck(1)
  let start = k.cpt.stack.lsPeekMemRef(^1)

  if start >= k.cpt.msg.data.len:
    k.cpt.stack.lsTop 0
    return ok()

  # If the data does not take 32 bytes, pad with zeros
  let
    endRange = min(k.cpt.msg.data.len - 1, start + 31)
    presentBytes = endRange - start

  # We rely on value being initialized with 0 by default
  var value: array[32, byte]
  assign(value.toOpenArray(0, presentBytes), k.cpt.msg.data.toOpenArray(start, endRange))
  k.cpt.stack.lsTop value
  ok()

proc callDataSizeOp (k: var VmCtx): EvmResultVoid =
  ## 0x36, Get size of input data in current environment.
  k.cpt.stack.push k.cpt.msg.data.len.u256


proc callDataCopyOp (k: var VmCtx): EvmResultVoid =
  ## 0x37, Copy input data in current environment to memory.
  ? k.cpt.stack.lsCheck(3)
  let
    cpt = k.cpt
    memPos  = cpt.stack.lsPeekMemRef(^1)
    copyPos = cpt.stack.lsPeekMemRef(^2)
    len     = cpt.stack.lsPeekMemRef(^3)

  cpt.stack.lsShrink(3)
  ? cpt.opcodeGasCost(CallDataCopy,
    cpt.gasCosts[CallDataCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "CallDataCopy fee")

  cpt.memory.writePadded(cpt.msg.data, memPos, copyPos, len)
  ok()


proc codeSizeOp (k: var VmCtx): EvmResultVoid =
  ## 0x38, Get size of code running in current environment.
  let cpt = k.cpt
  cpt.stack.push cpt.code.len


proc codeCopyOp (k: var VmCtx): EvmResultVoid =
  ## 0x39, Copy code running in current environment to memory.
  ? k.cpt.stack.lsCheck(3)
  let
    cpt = k.cpt
    memPos  = cpt.stack.lsPeekMemRef(^1)
    copyPos = cpt.stack.lsPeekMemRef(^2)
    len     = cpt.stack.lsPeekMemRef(^3)

  cpt.stack.lsShrink(3)
  ? cpt.opcodeGasCost(CodeCopy,
    cpt.gasCosts[CodeCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "CodeCopy fee")

  cpt.memory.writePadded(cpt.code.bytes, memPos, copyPos, len)
  ok()

proc gasPriceOp (k: var VmCtx): EvmResultVoid =
  ## 0x3A, Get price of gas in current environment.
  k.cpt.stack.push k.cpt.getGasPrice()

# -----------

proc extCodeSizeOp (k: var VmCtx): EvmResultVoid =
  ## 0x3b, Get size of an account's code
  ? k.cpt.stack.lsCheck(1)
  let
    cpt = k.cpt
    address = cpt.stack.lsPeekAddress(^1)

  cpt.stack.lsTop cpt.getCodeSize(address)
  ok()

proc extCodeSizeEIP2929Op (k: var VmCtx): EvmResultVoid =
  ## 0x3b, Get size of an account's code
  ? k.cpt.stack.lsCheck(1)
  let
    cpt = k.cpt
    address = cpt.stack.lsPeekAddress(^1)
    gasCost = cpt.gasEip2929AccountCheck(address)

  ? cpt.opcodeGasCost(ExtCodeSize, gasCost, reason = "ExtCodeSize EIP2929")
  cpt.stack.lsTop cpt.getCodeSize(address)
  ok()

# -----------

proc extCodeCopyOp (k: var VmCtx): EvmResultVoid =
  ## 0x3c, Copy an account's code to memory.
  ? k.cpt.stack.lsCheck(4)
  let
    cpt = k.cpt
    address = cpt.stack.lsPeekAddress(^1)
    memPos  = cpt.stack.lsPeekMemRef(^2)
    codePos = cpt.stack.lsPeekMemRef(^3)
    len     = cpt.stack.lsPeekMemRef(^4)

  cpt.stack.lsShrink(4)
  ? cpt.opcodeGasCost(ExtCodeCopy,
      cpt.gasCosts[ExtCodeCopy].m_handler(cpt.memory.len, memPos, len),
      reason = "ExtCodeCopy fee")

  let code = cpt.getCode(address)
  cpt.memory.writePadded(code.bytes, memPos, codePos, len)
  ok()


proc extCodeCopyEIP2929Op (k: var VmCtx): EvmResultVoid =
  ## 0x3c, Copy an account's code to memory.
  ? k.cpt.stack.lsCheck(4)
  let
    cpt = k.cpt
    address = cpt.stack.lsPeekAddress(^1)
    memPos  = cpt.stack.lsPeekMemRef(^2)
    codePos = cpt.stack.lsPeekMemRef(^3)
    len     = cpt.stack.lsPeekMemRef(^4)
    gasCost = cpt.gasCosts[ExtCodeCopy].m_handler(cpt.memory.len, memPos, len) +
                cpt.gasEip2929AccountCheck(address)

  cpt.stack.lsShrink(4)
  ? cpt.opcodeGasCost(ExtCodeCopy, gasCost, reason = "ExtCodeCopy EIP2929")

  let code = cpt.getCode(address)
  cpt.memory.writePadded(code.bytes(), memPos, codePos, len)
  ok()

# -----------

proc returnDataSizeOp (k: var VmCtx): EvmResultVoid =
  ## 0x3d, Get size of output data from the previous call from the
  ##       current environment.
  k.cpt.stack.push k.cpt.returnData.len


proc returnDataCopyOp (k: var VmCtx): EvmResultVoid =
  ## 0x3e, Copy output data from the previous call to memory.
  ? k.cpt.stack.lsCheck(3)
  let
    cpt = k.cpt
    memPos  = cpt.stack.lsPeekMemRef(^1)
    copyPos = cpt.stack.lsPeekMemRef(^2)
    len     = cpt.stack.lsPeekMemRef(^3)
    gasCost = cpt.gasCosts[ReturnDataCopy].m_handler(
                cpt.memory.len, memPos, len)

  cpt.stack.lsShrink(3)
  ? cpt.opcodeGasCost(ReturnDataCopy, gasCost, reason = "returnDataCopy fee")

  if copyPos + len > cpt.returnData.len:
    return err(opErr(OutOfBounds))
  cpt.memory.writePadded(cpt.returnData, memPos, copyPos, len)
  ok()

# ---------------

proc extCodeHashOp (k: var VmCtx): EvmResultVoid =
  ## 0x3f, Returns the keccak256 hash of a contract’s code
  ? k.cpt.stack.lsCheck(1)
  let
    cpt = k.cpt
    address = cpt.stack.lsPeekAddress(^1)

  cpt.stack.lsTop cpt.getCodeHash(address)
  ok()

proc extCodeHashEIP2929Op (k: var VmCtx): EvmResultVoid =
  ## 0x3f, EIP2929: Returns the keccak256 hash of a contract’s code
  ? k.cpt.stack.lsCheck(1)
  let
    cpt = k.cpt
    address = cpt.stack.lsPeekAddress(^1)
    gasCost = cpt.gasEip2929AccountCheck(address)

  ? cpt.opcodeGasCost(ExtCodeHash, gasCost, reason = "ExtCodeHash EIP2929")
  cpt.stack.lsTop cpt.getCodeHash(address)
  ok()

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  VmOpExecEnvInfo*: seq[VmOpExec] = @[

    (opCode: Address,         ## 0x20, Address
     forks: VmOpAllForks,
     name: "address",
     info: "Get address of currently executing account",
     exec: VmOpFn addressOp),


    (opCode: Balance,         ## 0x31, Balance
     forks: VmOpAllForks - VmOpBerlinAndLater,
     name: "balance",
     info: "Get balance of the given account",
     exec: balanceOp),


    (opCode: Balance,         ## 0x31, Balance for Berlin and later
     forks: VmOpBerlinAndLater,
     name: "balanceEIP2929",
     info: "EIP2929: Get balance of the given account",
     exec: balanceEIP2929Op),


    (opCode: Origin,          ## 0x32, Origination address
     forks: VmOpAllForks,
     name: "origin",
     info: "Get execution origination address",
     exec: originOp),


    (opCode: Caller,          ## 0x33, Caller address
     forks: VmOpAllForks,
     name: "caller",
     info: "Get caller address",
     exec: callerOp),


    (opCode: CallValue,       ## 0x34, Execution deposited value
     forks: VmOpAllForks,
     name: "callValue",
     info: "Get deposited value by the instruction/transaction " &
           "responsible for this execution",
     exec: callValueOp),


    (opCode: CallDataLoad,    ## 0x35, Input data
     forks: VmOpAllForks,
     name: "callDataLoad",
     info: "Get input data of current environment",
     exec: callDataLoadOp),


    (opCode: CallDataSize,    ## 0x36, Size of input data
     forks: VmOpAllForks,
     name: "callDataSize",
     info: "Get size of input data in current environment",
     exec: callDataSizeOp),


    (opCode: CallDataCopy,    ## 0x37, Copy input data to memory.
     forks: VmOpAllForks,
     name: "callDataCopy",
     info: "Copy input data in current environment to memory",
     exec: callDataCopyOp),


    (opCode: CodeSize,       ## 0x38, Size of code
     forks: VmOpAllForks,
     name: "codeSize",
     info: "Get size of code running in current environment",
     exec: codeSizeOp),


    (opCode: CodeCopy,       ## 0x39, Copy code to memory.
     forks: VmOpAllForks,
     name: "codeCopy",
     info: "Copy code running in current environment to memory",
     exec: codeCopyOp),


    (opCode: GasPrice,       ## 0x3a, Gas price
     forks: VmOpAllForks,
     name: "gasPrice",
     info: "Get price of gas in current environment",
     exec: gasPriceOp),


    (opCode: ExtCodeSize,    ## 0x3b, Account code size
     forks: VmOpAllForks - VmOpBerlinAndLater,
     name: "extCodeSize",
     info: "Get size of an account's code",
     exec: extCodeSizeOp),


    (opCode: ExtCodeSize,    ## 0x3b, Account code size for Berlin and later
     forks: VmOpBerlinAndLater,
     name: "extCodeSizeEIP2929",
     info: "EIP2929: Get size of an account's code",
     exec: extCodeSizeEIP2929Op),


    (opCode: ExtCodeCopy,    ## 0x3c, Account code copy to memory.
     forks: VmOpAllForks - VmOpBerlinAndLater,
     name: "extCodeCopy",
     info: "Copy an account's code to memory",
     exec: extCodeCopyOp),


    (opCode: ExtCodeCopy,    ## 0x3c, Account Code-copy for Berlin and later
     forks: VmOpBerlinAndLater,
     name: "extCodeCopyEIP2929",
     info: "EIP2929: Copy an account's code to memory",
     exec: extCodeCopyEIP2929Op),


    (opCode: ReturnDataSize, ## 0x3d, Previous call output data size
     forks: VmOpByzantiumAndLater,
     name: "returnDataSize",
     info: "Get size of output data from the previous call " &
           "from the current environment",
     exec: returnDataSizeOp),


    (opCode: ReturnDataCopy, ## 0x3e, Previous call output data copy to memory
     forks: VmOpByzantiumAndLater,
     name: "returnDataCopy",
     info: "Copy output data from the previous call to memory",
     exec: returnDataCopyOp),


    (opCode: ExtCodeHash,    ## 0x3f, Contract hash
     forks: VmOpConstantinopleAndLater - VmOpBerlinAndLater,
     name: "extCodeHash",
     info: "Returns the keccak256 hash of a contract’s code",
     exec: extCodeHashOp),


    (opCode: ExtCodeHash,    ## 0x3f, Contract hash for berlin and later
     forks: VmOpBerlinAndLater,
     name: "extCodeHashEIP2929",
     info: "EIP2929: Returns the keccak256 hash of a contract’s code",
     exec: extCodeHashEIP2929Op)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
