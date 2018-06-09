# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables,
  constants, vm_state,
  opcode_values, stint, eth_common,
  vm / [code_stream, memory, stack],
  ./logging

export GasInt

type
  BaseComputation* = ref object of RootObj
    # The execution computation
    vmState*:               BaseVMState
    msg*:                   Message
    memory*:                Memory
    stack*:                 Stack
    gasMeter*:              GasMeter
    code*:                  CodeStream
    children*:              seq[BaseComputation]
    rawOutput*:             string
    returnData*:            string
    error*:                 Error
    logEntries*:            seq[(EthAddress, seq[UInt256], string)]
    shouldEraseReturnData*: bool
    accountsToDelete*:      Table[EthAddress, EthAddress]
    opcodes*:               Table[Op, Opcode] # TODO array[Op, Opcode]
    precompiles*:           Table[string, Opcode]
    gasCosts*:              GasCosts # TODO separate opcode processing and gas computation

  Error* = ref object
    info*:                  string
    burnsGas*:              bool
    erasesReturnData*:      bool

  Opcode* = ref object of RootObj
    kind*: Op
    #of VARIABLE_GAS_COST_OPS:
    #  gasCostHandler*: proc(computation: var BaseComputation): UInt256
    ## so, we could have special logic that separates all gas cost calculations
    ## from actual opcode execution
    ## that's what parity does:
    ##   it uses the peek methods of the stack and calculates the cost
    ##   then it actually pops/pushes stuff in exec
    ## I followed the py-evm approach which does that in opcode logic
    gasCostKind*: GasCostKind
    runLogic*:  proc(computation: var BaseComputation)

  GasMeter* = ref object
    logger*: Logger
    gasRefunded*: GasInt
    startGas*: GasInt
    gasRemaining*: GasInt

  Message* = ref object
    # A message for VM computation

    # depth = None

    # code = None
    # codeAddress = None

    # createAddress = None

    # shouldTransferValue = None
    # isStatic = None

    # logger = logging.getLogger("evm.vm.message.Message")

    gas*:                     GasInt
    gasPrice*:                GasInt
    to*:                      EthAddress
    sender*:                  EthAddress
    value*:                   UInt256
    data*:                    seq[byte]
    code*:                    string
    internalOrigin*:          EthAddress
    internalCodeAddress*:     EthAddress
    depth*:                   int
    internalStorageAddress*:  EthAddress
    shouldTransferValue*:     bool
    isStatic*:                bool
    isCreate*:                bool

  MessageOptions* = ref object
    origin*:                  EthAddress
    depth*:                   int
    createAddress*:           EthAddress
    codeAddress*:             EthAddress
    shouldTransferValue*:     bool
    isStatic*:                bool
