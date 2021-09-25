# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../nimbus/[config, chain_config, constants, genesis],
  ../../nimbus/db/db_chain,
  eth/[p2p, trie/db] # ,  stint

proc blockChainForTesting*(network: NetworkID): BaseChainDB =
  let boot = CustomGenesis(
    genesis: network.defaultGenesisBlockForNetwork,
    config:  network.chainConfig)

  result = BaseChainDB(
    db: newMemoryDb(),
    config: boot.config)

  result.populateProgress
  boot.genesis.commit(result)

# End
