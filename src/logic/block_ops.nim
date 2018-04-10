# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

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
  # TODO: EthTime is an alias of Time, which is a distinct int64 so can't use u256(int64)
  # This may have implications for different platforms.
  stack.push(vmState.timestamp.uint64.u256) 

proc number*(computation) =
  stack.push(vmState.blockNumber)

proc difficulty*(computation) =
  stack.push(vmState.difficulty)

proc gaslimit*(computation) =
  stack.push(vmState.gasLimit)

