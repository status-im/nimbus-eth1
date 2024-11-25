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

proc addressOp(cpt: VmCpt): EvmResultVoid =
  ## 0x30, Get address of currently executing account.
  cpt.stack.push cpt.msg.contractAddress

# ------------------

proc balanceOp(cpt: VmCpt): EvmResultVoid =
  ## 0x31, Get balance of the given account.
  template balance256(address): auto =
    cpt.getBalance(address)
  cpt.stack.unaryAddress(balance256)

proc balanceEIP2929Op(cpt: VmCpt): EvmResultVoid =
  ## 0x31, EIP292: Get balance of the given account for Berlin and later
  template balanceEIP2929(address): auto =
    let gasCost = cpt.gasEip2929AccountCheck(address)
    ? cpt.opcodeGasCost(Balance, gasCost, reason = "Balance EIP2929")
    cpt.getBalance(address)
  cpt.stack.unaryAddress(balanceEIP2929)

# ------------------

proc originOp(cpt: VmCpt): EvmResultVoid =
  ## 0x32, Get execution origination address.
  cpt.stack.push cpt.getOrigin()

proc callerOp(cpt: VmCpt): EvmResultVoid =
  ## 0x33, Get caller address.
  cpt.stack.push cpt.msg.sender

proc callValueOp(cpt: VmCpt): EvmResultVoid =
  ## 0x34, Get deposited value by the instruction/transaction
  ##       responsible for this execution
  cpt.stack.push cpt.msg.value

proc callDataLoadOp(cpt: VmCpt): EvmResultVoid =
  ## 0x35, Get input data of current environment
  ? cpt.stack.lsCheck(1)
  let start = cpt.stack.lsPeekMemRef(^1)

  if start >= cpt.msg.data.len:
    cpt.stack.lsTop 0
    return ok()

  # If the data does not take 32 bytes, pad with zeros
  let
    endRange = min(cpt.msg.data.len - 1, start + 31)
    presentBytes = endRange - start

  # We rely on value being initialized with 0 by default
  var value: array[32, byte]
  assign(value.toOpenArray(0, presentBytes), cpt.msg.data.toOpenArray(start, endRange))
  cpt.stack.lsTop value
  ok()

proc callDataSizeOp(cpt: VmCpt): EvmResultVoid =
  ## 0x36, Get size of input data in current environment.
  cpt.stack.push cpt.msg.data.len.u256


proc callDataCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0x37, Copy input data in current environment to memory.
  ? cpt.stack.lsCheck(3)
  let
    memPos  = cpt.stack.lsPeekMemRef(^1)
    copyPos = cpt.stack.lsPeekMemRef(^2)
    len     = cpt.stack.lsPeekMemRef(^3)

  cpt.stack.lsShrink(3)
  ? cpt.opcodeGasCost(CallDataCopy,
    cpt.gasCosts[CallDataCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "CallDataCopy fee")

  cpt.memory.writePadded(cpt.msg.data, memPos, copyPos, len)
  ok()


proc codeSizeOp(cpt: VmCpt): EvmResultVoid =
  ## 0x38, Get size of code running in current environment.
  cpt.stack.push cpt.code.len


proc codeCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0x39, Copy code running in current environment to memory.
  ? cpt.stack.lsCheck(3)
  let
    memPos  = cpt.stack.lsPeekMemRef(^1)
    copyPos = cpt.stack.lsPeekMemRef(^2)
    len     = cpt.stack.lsPeekMemRef(^3)

  cpt.stack.lsShrink(3)
  ? cpt.opcodeGasCost(CodeCopy,
    cpt.gasCosts[CodeCopy].m_handler(cpt.memory.len, memPos, len),
    reason = "CodeCopy fee")

  cpt.memory.writePadded(cpt.code.bytes, memPos, copyPos, len)
  ok()

proc gasPriceOp(cpt: VmCpt): EvmResultVoid =
  ## 0x3A, Get price of gas in current environment.
  cpt.stack.push cpt.getGasPrice()

# -----------

proc extCodeSizeOp(cpt: VmCpt): EvmResultVoid =
  ## 0x3b, Get size of an account's code
  template ecs256(address): auto =
    cpt.getCodeSize(address)
  cpt.stack.unaryAddress(ecs256)

proc extCodeSizeEIP2929Op(cpt: VmCpt): EvmResultVoid =
  ## 0x3b, Get size of an account's code (EIP-2929)
  template ecsEIP2929(address): auto =
    let gasCost = cpt.gasEip2929AccountCheck(address)
    ? cpt.opcodeGasCost(ExtCodeSize, gasCost, reason = "ExtCodeSize EIP2929")
    cpt.getCodeSize(address)

  cpt.stack.unaryAddress(ecsEIP2929)

proc extCodeSizeEIP7702Op(cpt: VmCpt): EvmResultVoid =
  ## 0x3b, Get size of an account's code (EIP-7702)
  template ecsEIP7702(address): auto =
    let gasCost = cpt.gasEip2929AccountCheck(address)
    ? cpt.opcodeGasCost(ExtCodeSize, gasCost, reason = "ExtCodeSize EIP7702")
    cpt.resolveCodeSize(address)

  cpt.stack.unaryAddress(ecsEIP7702)

# -----------

proc extCodeCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0x3c, Copy an account's code to memory.
  ? cpt.stack.lsCheck(4)
  let
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


proc extCodeCopyEIP2929Op(cpt: VmCpt): EvmResultVoid =
  ## 0x3c, Copy an account's code to memory (EIP-2929).
  ? cpt.stack.lsCheck(4)
  let
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

proc extCodeCopyEIP7702Op(cpt: VmCpt): EvmResultVoid =
  ## 0x3c, Copy an account's code to memory (EIP-7702).
  ? cpt.stack.lsCheck(4)
  let
    address = cpt.stack.lsPeekAddress(^1)
    memPos  = cpt.stack.lsPeekMemRef(^2)
    codePos = cpt.stack.lsPeekMemRef(^3)
    len     = cpt.stack.lsPeekMemRef(^4)
    gasCost = cpt.gasCosts[ExtCodeCopy].m_handler(cpt.memory.len, memPos, len) +
                cpt.gasEip2929AccountCheck(address) +
                cpt.gasEip7702CodeCheck(address)

  cpt.stack.lsShrink(4)
  ? cpt.opcodeGasCost(ExtCodeCopy, gasCost, reason = "ExtCodeCopy EIP7702")

  let code = cpt.resolveCode(address)
  cpt.memory.writePadded(code.bytes(), memPos, codePos, len)
  ok()

# -----------

proc returnDataSizeOp(cpt: VmCpt): EvmResultVoid =
  ## 0x3d, Get size of output data from the previous call from the
  ##       current environment.
  cpt.stack.push cpt.returnData.len


proc returnDataCopyOp(cpt: VmCpt): EvmResultVoid =
  ## 0x3e, Copy output data from the previous call to memory.
  ? cpt.stack.lsCheck(3)
  let
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

proc extCodeHashOp(cpt: VmCpt): EvmResultVoid =
  ## 0x3f, Returns the keccak256 hash of a contract’s code
  template ech256(address): auto =
    cpt.getCodeHash(address)
  cpt.stack.unaryAddress(ech256)

proc extCodeHashEIP2929Op(cpt: VmCpt): EvmResultVoid =
  ## 0x3f, Returns the keccak256 hash of a contract’s code (EIP-2929)
  template echEIP2929(address): auto =
    let gasCost = cpt.gasEip2929AccountCheck(address)
    ? cpt.opcodeGasCost(ExtCodeHash, gasCost, reason = "ExtCodeHash EIP2929")
    cpt.getCodeHash(address)
  cpt.stack.unaryAddress(echEIP2929)

proc extCodeHashEIP7702Op(cpt: VmCpt): EvmResultVoid =
  ## 0x3f, Returns the keccak256 hash of a contract’s code (EIP-7702)
  template echEIP7702(address): auto =
    let gasCost = cpt.gasEip2929AccountCheck(address)
    ? cpt.opcodeGasCost(ExtCodeHash, gasCost, reason = "ExtCodeHash EIP7702")
    cpt.resolveCodeHash(address)
  cpt.stack.unaryAddress(echEIP7702)

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


    (opCode: ExtCodeSize,    ## 0x3b, Account code size for Berlin through Cancun
     forks: VmOpBerlinAndLater - VmOpPragueAndLater,
     name: "extCodeSizeEIP2929",
     info: "EIP2929: Get size of an account's code",
     exec: extCodeSizeEIP2929Op),


    (opCode: ExtCodeSize,    ## 0x3b, Account code size for Prague and later
     forks: VmOpPragueAndLater,
     name: "extCodeSizeEIP7702",
     info: "EIP7702: Get size of an account's code",
     exec: extCodeSizeEIP7702Op),


    (opCode: ExtCodeCopy,    ## 0x3c, Account code copy to memory.
     forks: VmOpAllForks - VmOpBerlinAndLater,
     name: "extCodeCopy",
     info: "Copy an account's code to memory",
     exec: extCodeCopyOp),


    (opCode: ExtCodeCopy,    ## 0x3c, Account Code-copy for Berlin through Cancun
     forks: VmOpBerlinAndLater - VmOpPragueAndLater,
     name: "extCodeCopyEIP2929",
     info: "EIP2929: Copy an account's code to memory",
     exec: extCodeCopyEIP2929Op),


    (opCode: ExtCodeCopy,    ## 0x3c, Account code copy for Prague and later
     forks: VmOpPragueAndLater,
     name: "extCodeCopyEIP7702",
     info: "EIP7702: Copy an account's code to memory",
     exec: extCodeCopyEIP7702Op),


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


    (opCode: ExtCodeHash,    ## 0x3f, Contract hash for Berlin through Cancun
     forks: VmOpBerlinAndLater - VmOpPragueAndLater,
     name: "extCodeHashEIP2929",
     info: "EIP2929: Returns the keccak256 hash of a contract’s code",
     exec: extCodeHashEIP2929Op),


    (opCode: ExtCodeHash,    ## 0x3f, Contract hash for Prague and later
     forks: VmOpPragueAndLater,
     name: "extCodeHashEIP7702",
     info: "EIP7702: Returns the keccak256 hash of a contract’s code",
     exec: extCodeHashEIP7702Op)]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
