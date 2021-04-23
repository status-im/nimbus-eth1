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

# Including types.nim and others unless included (not imported) into
# oph_kludge.nim
#
when not declared(Computation):
  import
    ../../../db/accounts_cache,
    ../../state,
    ../../types,
    ../gas_costs,
    ../gas_meter,
    eth/common

import
  ../../../errors,
  eth/common/eth_types,
  macros,
  stint

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc gasEip2929AccountCheck*(c: Computation;
                             address: EthAddress, prevCost = 0.GasInt) =
  c.vmState.mutateStateDB:
    let gasCost = if not db.inAccessList(address):
                    db.accessList(address)
                    ColdAccountAccessCost
                  else:
                    WarmStorageReadCost

    c.gasMeter.consumeGas(
      gasCost - prevCost,
      reason = "gasEIP2929AccountCheck")


template checkInStaticContext*(c: Computation) =
  ## Verify static context in handler function, raise an error otherwise
  if emvcStatic == c.msg.flags:
    # TODO: if possible, this check only appear
    # when fork >= FkByzantium
    raise newException(
      StaticContextError,
      "Cannot modify state while inside of STATICCALL context")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

