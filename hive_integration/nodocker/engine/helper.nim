# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/[common, rlp],
  chronicles,
  web3/execution_types,
  ../../../nimbus/beacon/web3_eth_conv,
  ./engine_client,
  ./types

proc txInPayload*(payload: ExecutionPayload, txHash: Hash32): bool =
  for txBytes in payload.transactions:
    let currTx = rlp.decode(seq[byte](txBytes), Transaction)
    if rlpHash(currTx) == txHash:
      return true

proc checkPrevRandaoValue*(client: RpcClient, expectedPrevRandao: Bytes32, blockNumber: uint64): bool =
  let storageKey = blockNumber.u256
  let r = client.storageAt(prevRandaoContractAddr, storageKey)
  r.expectStorageEqual(expectedPrevRandao)
  return true
