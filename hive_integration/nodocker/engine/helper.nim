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
  eth/[common, rlp],
  ../../../nimbus/beacon/execution_types,
  ../../../nimbus/beacon/web3_eth_conv

proc txInPayload*(payload: ExecutionPayload, txHash: common.Hash256): bool =
  for txBytes in payload.transactions:
    let currTx = rlp.decode(common.Blob txBytes, Transaction)
    if rlpHash(currTx) == txHash:
      return true
