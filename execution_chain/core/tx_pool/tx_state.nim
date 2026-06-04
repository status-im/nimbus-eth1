# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  results,
  minilru,
  eth/common/[base, addresses],
  ../../db/core_db

# The primary function of TxState is to fetch account state
# but at the same time avoid being recorded in the BAL

type
  TxState* = object
    txFrame: CoreDbTxRef
    cache: LruCache[Address, AccountNonce]

func init*(state: var TxState, db: CoreDbTxRef) =
  state.txFrame = db
  state.cache = typeof(state.cache).init(500)

proc getNonce*(state: var TxState, address: Address): AccountNonce =
  state.cache.get(address).valueOr:
    let
      accPath = address.computeAccPath
      rc = state.txFrame.fetchAccount accPath
      nonce = if rc.isOk: rc.value.nonce
              else: 0.AccountNonce
    state.cache.put(address, nonce)
    nonce

func update*(state: var TxState, address: Address, nonce: AccountNonce) =
  discard state.cache.update(address, nonce)
