# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
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

{.push raises: [].}

import
  ../../evm_errors,
  ../../types,
  ../gas_costs,
  eth/common,
  eth/common/eth_types,
  stint

when defined(evmc_enabled):
  import
    ../../evmc_api,
    evmc/evmc
else:
  import
    ../../state,
    ../../../db/ledger

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc gasEip2929AccountCheck*(c: Computation; address: Address): GasInt =
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

proc gasEip2929AccountCheck*(c: Computation; address: Address, slot: UInt256): GasInt =
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

func checkInStaticContext*(c: Computation): EvmResultVoid =
  ## Verify static context in handler function, raise an error otherwise
  if EVMC_STATIC in c.msg.flags:
    # TODO: if possible, this check only appear
    # when fork >= FkByzantium
    return err(opErr(StaticContext))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

