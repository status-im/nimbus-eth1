# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth_common/eth_types,
  ../../db/db_chain, ../../constants,
  ../../utils/header,
  ../base,
  ../forks/f20150730_frontier/frontier_vm,
  ../forks/f20161018_tangerine_whistle/tangerine_vm

# Note (mamy): refactoring is in progress (2018-05-23), this is redundant with
#  - `Chain` in src/chain.nim, to be honest I don't understand the need of this abstraction at the moment
#  - `toFork` in src/constant. This is temporary until more VMs are implemented

proc newNimbusVM*(header: BlockHeader, chainDB: BaseChainDB): VM =

  # TODO: deal with empty BlockHeader
  if header.blockNumber < FORK_TANGERINE_WHISTLE_BLKNUM:
    result = newFrontierVM(header, chainDB)
  else:
    result = newTangerineVM(header, chainDB)
