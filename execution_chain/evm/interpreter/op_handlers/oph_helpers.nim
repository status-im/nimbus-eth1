# Nimbus
# Copyright (c) 2021-2026 Status Research & Development GmbH
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
  eth/common/[addresses, base],
  ../../[state, computation],
  ../../../db/ledger,
  ../../../common/evmforks

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc gasEip2929AccountCheck*(c: Computation; address: Address): GasInt =
  c.vmState.mutateLedger:
    if not ledger.inAccessList(address):
      ledger.accessList(address)
      if c.fork >= FkAmsterdam:
        COLD_ACCOUNT_ACCESS_8038
      else:
        COLD_ACCOUNT_ACCESS_2929
    else:
      WarmStorageReadCost

proc gasEip8038AccountCheck*(c: Computation; address: Address): GasInt =
  c.vmState.mutateLedger:
    if not ledger.inAccessList(address):
      ledger.accessList(address)
      COLD_ACCOUNT_ACCESS_8038
    else:
      WarmStorageReadCost

proc gasEip2929AccountCheck*(c: Computation; address: Address, slot: UInt256): GasInt =
  c.vmState.mutateLedger:
    if not ledger.inAccessList(address, slot):
      ledger.accessList(address, slot)
      if c.fork >= FkAmsterdam:
        COLD_STORAGE_ACCESS_8038
      else:
        COLD_STORAGE_ACCESS_2929
    else:
      WarmStorageReadCost

proc gasEip8038AccountCheck*(c: Computation; address: Address, slot: UInt256): GasInt =
  c.vmState.mutateLedger:
    if not ledger.inAccessList(address, slot):
      ledger.accessList(address, slot)
      COLD_STORAGE_ACCESS_8038
    else:
      WarmStorageReadCost

func checkInStaticContext*(c: Computation): EvmResultVoid =
  ## Verify static context in handler function, raise an error otherwise
  if MsgFlags.Static in c.msg.flags:
    # TODO: if possible, this check only appear
    # when fork >= FkByzantium
    return err(opErr(StaticContext))

  ok()

proc delegateResolutionCost*(c: Computation, address: Address): GasInt =
  c.vmState.mutateLedger:
    if not ledger.inAccessList(address):
      ledger.accessList(address)
      if c.fork >= FkAmsterdam:
        COLD_ACCOUNT_ACCESS_8038
      else:
        COLD_ACCOUNT_ACCESS_2929
    else:
      return WarmStorageReadCost

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
