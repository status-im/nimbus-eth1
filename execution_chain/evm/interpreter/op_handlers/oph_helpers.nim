# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
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
  ../../../constants,
  ../../evm_errors,
  ../../interpreter/utils/utils_numeric,
  ../../types,
  ../gas_costs,
  eth/common/[addresses, base],
  ../../state,
  ../../../db/ledger

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc gasEip2929AccountCheck*(c: Computation; address: Address): GasInt =
  c.vmState.mutateLedger:
    result = if not db.inAccessList(address):
               db.accessList(address)
               ColdAccountAccessCost
             else:
               WarmStorageReadCost

proc gasEip2929AccountCheck*(c: Computation; address: Address, slot: UInt256): GasInt =
  c.vmState.mutateLedger:
    result = if not db.inAccessList(address, slot):
               db.accessList(address, slot)
               ColdSloadCost
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
    if not db.inAccessList(address):
      db.accessList(address)
      return ColdAccountAccessCost
    else:
      return WarmStorageReadCost

proc gasCallEIP7907*(c: Computation, codeAddress: Address): GasInt =
  c.vmState.mutateLedger:

    if not db.inCodeAccessList(codeAddress):
      db.codeAccessList(codeAddress)

      let
        code = db.getCode(codeAddress)
        excessContractSize = max(0, code.len - CODE_SIZE_THRESHOLD)
        largeContractCost = (ceil32(excessContractSize) * 2) div 32
      return GasInt(largeContractCost)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
