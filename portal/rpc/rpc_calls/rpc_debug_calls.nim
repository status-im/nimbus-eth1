# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import stint, json_rpc/[client, jsonmarshal], web3/conversions, web3/eth_api_types

export eth_api_types

createRpcSigsFromNim(RpcClient):
  proc debug_getBalanceByStateRoot(data: Address, stateRoot: Hash32): UInt256
  proc debug_getTransactionCountByStateRoot(data: Address, stateRoot: Hash32): Quantity
  proc debug_getStorageAtByStateRoot(
    data: Address, slot: UInt256, stateRoot: Hash32
  ): FixedBytes[32]

  proc debug_getCodeByStateRoot(data: Address, stateRoot: Hash32): seq[byte]
  proc debug_getProofByStateRoot(
    address: Address, slots: seq[UInt256], stateRoot: Hash32
  ): ProofResponse

  proc debug_callByStateRoot(
    tx: TransactionArgs, stateRoot: Hash32, blockId: Opt[BlockIdentifier]
  ): seq[byte]
