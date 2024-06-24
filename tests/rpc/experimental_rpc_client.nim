# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  json_rpc/rpcclient,
  json_rpc/errors,
  web3/eth_api

export
  rpcclient,
  errors,
  eth_api_types,
  conversions

createRpcSigsFromNim(RpcClient):
  proc exp_getProofsByBlockNumber(blockId: BlockIdentifier, statePostExecution: bool): seq[ProofResponse]
