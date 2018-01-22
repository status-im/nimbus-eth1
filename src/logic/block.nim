import
  ../constants, ../computation, ../vm/stack, ../vm_state

proc blockhash*(computation: var BaseComputation) =
  var blockNumber = computation.stack.popInt()
  var blockHash = computation.vmState.getAncestorHash(blockNumber)
  computation.stack.push(blockHash)

proc coinbase*(computation: var BaseComputation) =
  computation.stack.push(computation.vmState.coinbase)

proc timestamp*(computation: var BaseComputation) =
  computation.stack.push(computation.vmState.timestamp.int256)

proc difficulty*(computation: var BaseComputation) =
  computation.stack.push(computation.vmState.difficulty)

proc gaslimit*(computation: var BaseComputation) =
  computation.stack.push(computation.vmState.gasLimit)
