# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../../nimbus/common/common,
  ../../nimbus/[vm_state, vm_types],
  ../../nimbus/db/accounts_cache

proc coinbaseStateClearing*(vmState: BaseVMState,
                            miner: EthAddress,
                            fork: EVMFork,
                            touched = true) =
  # This is necessary due to the manner in which the state tests are
  # generated. State tests are generated from the BlockChainTest tests
  # in which these transactions are included in the larger context of a
  # block and thus, the mechanisms which would touch/create/clear the
  # coinbase account based on the mining reward are present during test
  # generation, but not part of the execution, thus we must artificially
  # create the account in VMs prior to the state clearing rules,
  # as well as conditionally cleaning up the coinbase account when left
  # empty in VMs after the state clearing rules came into effect.

  vmState.mutateStateDB:
    if touched:
      db.addBalance(miner, 0.u256)

    if fork >= FkSpurious:
      db.deleteAccountIfEmpty(miner)

    # db.persist is an important step when using accounts_cache
    # it will affect the account storage's location
    # during the next call to `getComittedStorage`
    # and the result of rootHash

    # do not clear cache, we need the cache when constructing
    # post state
    db.persist(clearCache = false)
