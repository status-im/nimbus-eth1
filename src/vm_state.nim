import
  strformat,
  logging, constants, errors, utils/state

type
  BaseVMState* = ref object of RootObj
    prevHeaders*: bool
    receipts*: bool
    computationClass*: bool
    chaindb*: bool
    accessLogs*: seq[bool]
    blockHeader*: bool
    name*: string

proc newBaseVMState*: BaseVMState =
  new(result)
  # result.chaindb = nil
  # result.blockHeader = nil
  # result.prevHeaders = nil
  # result.computationClass = nil
  # result.accessLogs = nil
  # result.receipts = nil

method logger*(vmState: BaseVMState): Logger =
  logging.getLogger(%"evm.vmState.{vmState.name}")
