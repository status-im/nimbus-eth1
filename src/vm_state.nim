import
  strformat, tables,
  logging, constants, bigints, errors, transaction, db/chain, utils/state, utils/header

type
  BaseVMState* = ref object of RootObj
    prevHeaders*: seq[Header]
    # receipts*:
    chaindb*: BaseChainDB
    # accessLogs*:
    blockHeader*: Header
    name*: string

proc newBaseVMState*: BaseVMState =
  new(result)
  result.prevHeaders = @[]
  result.name = "BaseVM"

method logger*(vmState: BaseVMState): Logger =
  logging.getLogger(&"evm.vmState.{vmState.name}")

method blockhash*(vmState: BaseVMState): cstring =
  vmState.blockHeader.hash

method coinbase*(vmState: BaseVMState): cstring =
  vmState.blockHeader.coinbase

method timestamp*(vmState: BaseVMState): int =
  vmState.blockHeader.timestamp

method blockNumber*(vmState: BaseVMState): Int256 =
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
