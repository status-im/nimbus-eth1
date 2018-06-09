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
  vm / [code_stream, memory, stack, forks/gas_costs],
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
    gasCosts*:              static[GasCosts]

  Error* = ref object
    info*:                  string
    burnsGas*:              bool
    erasesReturnData*:      bool

  Opcode* = ref object
    # TODO can't use a stack-allocated object because
    # "BaseComputation is not a concrete type"
    kind*: Op
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
