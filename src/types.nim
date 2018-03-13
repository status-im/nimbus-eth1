import
  tables,
  constants, vm_state, 
  opcode_values, ttmath,
  vm / [code_stream, gas_meter, memory, message, stack]

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
    logEntries*:            seq[(string, seq[UInt256], string)]
    shouldEraseReturnData*: bool
    accountsToDelete*:      Table[string, string]
    opcodes*:               Table[Op, Opcode] # TODO array[Op, Opcode]
    precompiles*:           Table[string, Opcode]

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
    gasCostConstant*: UInt256
    runLogic*:  proc(computation: var BaseComputation)
