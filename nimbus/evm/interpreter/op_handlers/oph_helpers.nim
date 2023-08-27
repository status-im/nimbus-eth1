# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Common Helper Functions
## ============================================
##

when defined(evmc_enabled):
  {.push raises: [CatchableError].} # basically the annotation type of a `Vm2OpFn`
else:
  {.push raises: [].}

import
  ../../../errors,
  ../../types,
  ../gas_costs,
  eth/common,
  eth/common/eth_types,
  stint

when defined(evmc_enabled):
  import ../../evmc_api, evmc/evmc
else:
  import
    ../../state,
    ../../../db/accounts_cache

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc gasEip2929AccountCheck*(c: Computation; address: EthAddress): GasInt =
  when defined(evmc_enabled):
    result = if c.host.accessAccount(address) == EVMC_ACCESS_COLD:
               ColdAccountAccessCost
             else:
               WarmStorageReadCost
  else:
    c.vmState.mutateStateDB:
      result = if not db.inAccessList(address):
                 db.accessList(address)
                 ColdAccountAccessCost
               else:
                 WarmStorageReadCost

proc gasEip2929AccountCheck*(c: Computation; address: EthAddress, slot: UInt256): GasInt =
  when defined(evmc_enabled):
    result = if c.host.accessStorage(address, slot) == EVMC_ACCESS_COLD:
               ColdSloadCost
             else:
               WarmStorageReadCost
  else:
    c.vmState.mutateStateDB:
      result = if not db.inAccessList(address, slot):
                 db.accessList(address, slot)
                 ColdSloadCost
               else:
                 WarmStorageReadCost

template checkInStaticContext*(c: Computation) =
  ## Verify static context in handler function, raise an error otherwise
  if EVMC_STATIC in c.msg.flags:
    # TODO: if possible, this check only appear
    # when fork >= FkByzantium
    raise newException(
      StaticContextError,
      "Cannot modify state while inside of STATICCALL context")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

