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
  stint

when not defined(evmc_enabled):
  import ../../state

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

const
  addressOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x30, Get address of currently executing account.
    k.cpt.stack.push k.cpt.msg.contractAddress

  # ------------------

  balanceOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x31, Get balance of the given account.
    let
      cpt = k.cpt
      address = ? cpt.stack.popAddress
    cpt.stack.push cpt.getBalance(address)

  balanceEIP2929Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x31, EIP292: Get balance of the given account for Berlin and later
    let
      cpt = k.cpt
      address = ? cpt.stack.popAddress()
      gasCost = cpt.gasEip2929AccountCheck(address)

    ? cpt.opcodeGastCost(Balance, gasCost, reason = "Balance EIP2929")
    cpt.stack.push cpt.getBalance(address)

  # ------------------

  originOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x32, Get execution origination address.
    k.cpt.stack.push k.cpt.getOrigin()

  callerOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x33, Get caller address.
    k.cpt.stack.push k.cpt.msg.sender

  callValueOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x34, Get deposited value by the instruction/transaction
    ##       responsible for this execution
    k.cpt.stack.push k.cpt.msg.value

  callDataLoadOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x35, Get input data of current environment
    let
      startPos = ? k.cpt.stack.popInt()
      start = startPos.cleanMemRef

    if start >= k.cpt.msg.data.len:
      return k.cpt.stack.push 0

    # If the data does not take 32 bytes, pad with zeros
    let
      endRange = min(k.cpt.msg.data.len - 1, start + 31)
      presentBytes = endRange - start

    # We rely on value being initialized with 0 by default
    var value: array[32, byte]
    value[0 .. presentBytes] = k.cpt.msg.data.toOpenArray(start, endRange)
    k.cpt.stack.push value


  callDataSizeOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x36, Get size of input data in current environment.
    k.cpt.stack.push k.cpt.msg.data.len.u256


  callDataCopyOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x37, Copy input data in current environment to memory.
    let (memStartPos, copyStartPos, size) = ? k.cpt.stack.popInt(3)

    # TODO tests: https://github.com/status-im/nimbus/issues/67
    let (memPos, copyPos, len) =
      (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)

    ? k.cpt.opcodeGastCost(CallDataCopy,
      k.cpt.gasCosts[CallDataCopy].m_handler(k.cpt.memory.len, memPos, len),
      reason = "CallDataCopy fee")

    k.cpt.memory.writePadded(k.cpt.msg.data, memPos, copyPos, len)
    ok()


  codeSizeOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x38, Get size of code running in current environment.
    let cpt = k.cpt
    cpt.stack.push cpt.code.len


  codeCopyOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x39, Copy code running in current environment to memory.
    let
      cpt = k.cpt
      (memStartPos, copyStartPos, size) = ? cpt.stack.popInt(3)

    # TODO tests: https://github.com/status-im/nimbus/issues/67
    let (memPos, copyPos, len) =
      (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)

    ? cpt.opcodeGastCost(CodeCopy,
      cpt.gasCosts[CodeCopy].m_handler(cpt.memory.len, memPos, len),
      reason = "CodeCopy fee")

    cpt.memory.writePadded(cpt.code.bytes, memPos, copyPos, len)
    ok()

  gasPriceOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3A, Get price of gas in current environment.
    k.cpt.stack.push k.cpt.getGasPrice()

  # -----------

  extCodeSizeOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3b, Get size of an account's code
    let
      cpt = k.cpt
      address = ? k.cpt.stack.popAddress()

    cpt.stack.push cpt.getCodeSize(address)

  extCodeSizeEIP2929Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3b, Get size of an account's code
    let
      cpt = k.cpt
      address = ? cpt.stack.popAddress()
      gasCost = cpt.gasEip2929AccountCheck(address)

    ? cpt.opcodeGastCost(ExtCodeSize, gasCost, reason = "ExtCodeSize EIP2929")
    cpt.stack.push cpt.getCodeSize(address)

  # -----------

  extCodeCopyOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3c, Copy an account's code to memory.
    let
      cpt = k.cpt
      address = ? cpt.stack.popAddress()
      (memStartPos, codeStartPos, size) = ? cpt.stack.popInt(3)
      (memPos, codePos, len) =
        (memStartPos.cleanMemRef, codeStartPos.cleanMemRef, size.cleanMemRef)

    ? cpt.opcodeGastCost(ExtCodeCopy,
        cpt.gasCosts[ExtCodeCopy].m_handler(cpt.memory.len, memPos, len),
        reason = "ExtCodeCopy fee")

    let codeBytes = cpt.getCode(address)
    cpt.memory.writePadded(codeBytes, memPos, codePos, len)
    ok()


  extCodeCopyEIP2929Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3c, Copy an account's code to memory.
    let
      cpt = k.cpt
      address = ? cpt.stack.popAddress()
      (memStartPos, codeStartPos, size) = ? cpt.stack.popInt(3)
      (memPos, codePos, len) = (memStartPos.cleanMemRef,
                                    codeStartPos.cleanMemRef, size.cleanMemRef)

      gasCost = cpt.gasCosts[ExtCodeCopy].m_handler(cpt.memory.len, memPos, len) +
                      cpt.gasEip2929AccountCheck(address)
    ? cpt.opcodeGastCost(ExtCodeCopy, gasCost, reason = "ExtCodeCopy EIP2929")

    let codeBytes = cpt.getCode(address)
    cpt.memory.writePadded(codeBytes, memPos, codePos, len)
    ok()

  # -----------

  returnDataSizeOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3d, Get size of output data from the previous call from the
    ##       current environment.
    k.cpt.stack.push k.cpt.returnData.len


  returnDataCopyOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3e, Copy output data from the previous call to memory.
    let
      (memStartPos, copyStartPos, size) = ? k.cpt.stack.popInt(3)
      (memPos, copyPos, len) =
        (memStartPos.cleanMemRef, copyStartPos.cleanMemRef, size.cleanMemRef)
      gasCost = k.cpt.gasCosts[ReturnDataCopy].m_handler(
       k.cpt.memory.len, memPos, len)

    ? k.cpt.opcodeGastCost(ReturnDataCopy, gasCost, reason = "returnDataCopy fee")

    if copyPos + len > k.cpt.returnData.len:
      return err(opErr(OutOfBounds))
    k.cpt.memory.writePadded(k.cpt.returnData, memPos, copyPos, len)
    ok()

  # ---------------

  extCodeHashOp: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3f, Returns the keccak256 hash of a contract’s code
    let
      cpt = k.cpt
      address = ? k.cpt.stack.popAddress()

    cpt.stack.push cpt.getCodeHash(address)

  extCodeHashEIP2929Op: Vm2OpFn = proc (k: var Vm2Ctx): EvmResultVoid =
    ## 0x3f, EIP2929: Returns the keccak256 hash of a contract’s code
    let
      cpt = k.cpt
      address = ? k.cpt.stack.popAddress()
      gasCost = cpt.gasEip2929AccountCheck(address)

    ? cpt.opcodeGastCost(ExtCodeHash, gasCost, reason = "ExtCodeHash EIP2929")
    cpt.stack.push cpt.getCodeHash(address)

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

const
  vm2OpExecEnvInfo*: seq[Vm2OpExec] = @[

    (opCode: Address,         ## 0x20, Address
     forks: Vm2OpAllForks,
     name: "address",
     info: "Get address of currently executing account",
     exec: (prep: vm2OpIgnore,
            run:  addressOp,
            post: vm2OpIgnore)),

    (opCode: Balance,         ## 0x31, Balance
     forks: Vm2OpAllForks - Vm2OpBerlinAndLater,
     name: "balance",
     info: "Get balance of the given account",
     exec: (prep: vm2OpIgnore,
            run:  balanceOp,
            post: vm2OpIgnore)),

    (opCode: Balance,         ## 0x31, Balance for Berlin and later
     forks: Vm2OpBerlinAndLater,
     name: "balanceEIP2929",
     info: "EIP2929: Get balance of the given account",
     exec: (prep: vm2OpIgnore,
            run:  balanceEIP2929Op,
            post: vm2OpIgnore)),

    (opCode: Origin,          ## 0x32, Origination address
     forks: Vm2OpAllForks,
     name: "origin",
     info: "Get execution origination address",
     exec: (prep: vm2OpIgnore,
            run:  originOp,
            post: vm2OpIgnore)),

    (opCode: Caller,          ## 0x33, Caller address
     forks: Vm2OpAllForks,
     name: "caller",
     info: "Get caller address",
     exec: (prep: vm2OpIgnore,
            run:  callerOp,
            post: vm2OpIgnore)),

    (opCode: CallValue,       ## 0x34, Execution deposited value
     forks: Vm2OpAllForks,
     name: "callValue",
     info: "Get deposited value by the instruction/transaction " &
           "responsible for this execution",
     exec: (prep: vm2OpIgnore,
            run:  callValueOp,
            post: vm2OpIgnore)),

    (opCode: CallDataLoad,    ## 0x35, Input data
     forks: Vm2OpAllForks,
     name: "callDataLoad",
     info: "Get input data of current environment",
     exec: (prep: vm2OpIgnore,
            run:  callDataLoadOp,
            post: vm2OpIgnore)),

    (opCode: CallDataSize,    ## 0x36, Size of input data
     forks: Vm2OpAllForks,
     name: "callDataSize",
     info: "Get size of input data in current environment",
     exec: (prep: vm2OpIgnore,
            run:  callDataSizeOp,
            post: vm2OpIgnore)),

    (opCode: CallDataCopy,    ## 0x37, Copy input data to memory.
     forks: Vm2OpAllForks,
     name: "callDataCopy",
     info: "Copy input data in current environment to memory",
     exec: (prep: vm2OpIgnore,
            run:  callDataCopyOp,
            post: vm2OpIgnore)),

    (opCode: CodeSize,       ## 0x38, Size of code
     forks: Vm2OpAllForks,
     name: "codeSize",
     info: "Get size of code running in current environment",
     exec: (prep: vm2OpIgnore,
            run:  codeSizeOp,
            post: vm2OpIgnore)),

    (opCode: CodeCopy,       ## 0x39, Copy code to memory.
     forks: Vm2OpAllForks,
     name: "codeCopy",
     info: "Copy code running in current environment to memory",
     exec: (prep: vm2OpIgnore,
            run:  codeCopyOp,
            post: vm2OpIgnore)),

    (opCode: GasPrice,       ## 0x3a, Gas price
     forks: Vm2OpAllForks,
     name: "gasPrice",
     info: "Get price of gas in current environment",
     exec: (prep: vm2OpIgnore,
            run:  gasPriceOp,
            post: vm2OpIgnore)),

    (opCode: ExtCodeSize,    ## 0x3b, Account code size
     forks: Vm2OpAllForks - Vm2OpBerlinAndLater,
     name: "extCodeSize",
     info: "Get size of an account's code",
     exec: (prep: vm2OpIgnore,
            run:  extCodeSizeOp,
            post: vm2OpIgnore)),

    (opCode: ExtCodeSize,    ## 0x3b, Account code size for Berlin and later
     forks: Vm2OpBerlinAndLater,
     name: "extCodeSizeEIP2929",
     info: "EIP2929: Get size of an account's code",
     exec: (prep: vm2OpIgnore,
            run:  extCodeSizeEIP2929Op,
            post: vm2OpIgnore)),

    (opCode: ExtCodeCopy,    ## 0x3c, Account code copy to memory.
     forks: Vm2OpAllForks - Vm2OpBerlinAndLater,
     name: "extCodeCopy",
     info: "Copy an account's code to memory",
     exec: (prep: vm2OpIgnore,
            run:  extCodeCopyOp,
            post: vm2OpIgnore)),

    (opCode: ExtCodeCopy,    ## 0x3c, Account Code-copy for Berlin and later
     forks: Vm2OpBerlinAndLater,
     name: "extCodeCopyEIP2929",
     info: "EIP2929: Copy an account's code to memory",
     exec: (prep: vm2OpIgnore,
            run:  extCodeCopyEIP2929Op,
            post: vm2OpIgnore)),

    (opCode: ReturnDataSize, ## 0x3d, Previous call output data size
     forks: Vm2OpByzantiumAndLater,
     name: "returnDataSize",
     info: "Get size of output data from the previous call " &
           "from the current environment",
     exec: (prep: vm2OpIgnore,
            run:  returnDataSizeOp,
            post: vm2OpIgnore)),

    (opCode: ReturnDataCopy, ## 0x3e, Previous call output data copy to memory
     forks: Vm2OpByzantiumAndLater,
     name: "returnDataCopy",
     info: "Copy output data from the previous call to memory",
     exec: (prep: vm2OpIgnore,
            run:  returnDataCopyOp,
            post: vm2OpIgnore)),

    (opCode: ExtCodeHash,    ## 0x3f, Contract hash
     forks: Vm2OpConstantinopleAndLater - Vm2OpBerlinAndLater,
     name: "extCodeHash",
     info: "Returns the keccak256 hash of a contract’s code",
     exec: (prep: vm2OpIgnore,
            run:  extCodeHashOp,
            post: vm2OpIgnore)),

    (opCode: ExtCodeHash,    ## 0x3f, Contract hash for berlin and later
     forks: Vm2OpBerlinAndLater,
     name: "extCodeHashEIP2929",
     info: "EIP2929: Returns the keccak256 hash of a contract’s code",
     exec: (prep: vm2OpIgnore,
            run:  extCodeHashEIP2929Op,
            post: vm2OpIgnore))]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
