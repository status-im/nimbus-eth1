import
  strformat, tables,
  logging, constants, bigints, errors, transaction, db/chain, utils/state, utils/header

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
  logging.getLogger(&"evm.vmState.{vmState.name}")

method blockhash*(vmState: BaseVMState): cstring =
  vmState.blockHeader.hash

method coinbase*(vmState: BaseVMState): cstring =
  vmState.blockHeader.coinbase

method timestamp*(vmState: BaseVMState): int =
  vmState.blockHeader.timestamp

method blockBumber*(vmState: BaseVMState): Int256 =
  vmState.blockHeader.blockNumber

method difficulty*(vmState: BaseVMState): Int256 =
  vmState.blockHeader.difficulty

method gasLimit*(vmState: BaseVMState): Int256 =
  vmState.blockHeader.gasLimit

method getAncestorHash*(vmState: BaseVMState, blockNumber: Int256): cstring =
  var ancestorDepth = vmState.blockHeader.blockNumber - blockNumber - 1.int256
  if ancestorDepth >= constants.MAX_PREV_HEADER_DEPTH or
     ancestorDepth < 0 or
     ancestorDepth >= vmState.prevHeaders.len.int256:
    return cstring""
  var header = vmState.prevHeaders[ancestorDepth.getInt]
  result = header.hash
