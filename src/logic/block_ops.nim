import
  ../constants, ../errors, ../computation, ../vm_state, ../types, .. / vm / [stack], ttmath

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
  stack.push(vmState.timestamp.uint64.u256) # TODO: EthTime (from Time) is distinct

proc number*(computation) =
  stack.push(vmState.blockNumber)

proc difficulty*(computation) =
  stack.push(vmState.difficulty)

proc gaslimit*(computation) =
  stack.push(vmState.gasLimit)

