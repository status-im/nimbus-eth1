# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  options, sets,
  eth/common, chronicles, ../db/accounts_cache,
  ../forks,
  ./computation, ./interpreter, ./state, ./types

proc execComputation*(c: Computation) =
  when defined(evmc_enabled):
    if not c.msg.isCreate and c.transactionHost.dbCompare:
      # NOTE: Because we `incNonce` we must add nonce to the `dbCompare` read-set
      # first.  For nonce we need to call `dbCompareNonce` directly.
      let nonce = c.vmState.readOnlyStateDB.getNonce(c.msg.sender)
      c.transactionHost.dbCompareNonce(c.msg.sender, nonce)

  if not c.msg.isCreate:
    c.vmState.mutateStateDB:
      db.incNonce(c.msg.sender)

  c.execCallOrCreate()

  if c.isSuccess:
    if c.fork < FkLondon:
      # EIP-3529: Reduction in refunds
      c.refundSelfDestruct()
    shallowCopy(c.vmState.selfDestructs, c.selfDestructs)
    shallowCopy(c.vmState.logEntries, c.logEntries)
    c.vmState.touchedAccounts.incl c.touchedAccounts

  c.vmstate.status = c.isSuccess
