import
  strformat, tables,
  logging, constants, errors, transaction, db/chain, utils/state, utils/header

type
  BaseVMState* = ref object of RootObj
    prevHeaders*: seq[Header]
    receipts*: seq[string]
    # computationClass*: bool
    chaindb*: BaseChainDB
    accessLogs*: seq[string]
    blockHeader*: Header
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
