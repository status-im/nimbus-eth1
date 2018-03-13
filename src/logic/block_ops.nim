import
  ../constants, ../errors, ../computation, ../vm_state, ../types, .. / vm / [stack]

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc blockhash*(computation) =
  let blockNumber = stack.popInt()
  let blockHash = vmState.getAncestorHash(blockNumber)
  stack.push(blockHash)

proc coinbase*(computation) =
  stack.push(vmState.coinbase)

proc timestamp*(computation) =
  stack.push(vmState.timestamp.u256)

proc number*(computation) =
  stack.push(vmState.blockNumber)

proc difficulty*(computation) =
  stack.push(vmState.difficulty)

proc gaslimit*(computation) =
  stack.push(vmState.gasLimit)

