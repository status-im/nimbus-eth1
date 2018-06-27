# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth_common/eth_types,
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
