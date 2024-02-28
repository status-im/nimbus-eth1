# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import stint, eth/[common, trie], ./state_proof_types

proc generateAccountProof*(
    state: AccountState, address: EthAddress
): AccountProof {.raises: [RlpError].} =
  let key = keccakHash(address).data
  state.getBranch(key).AccountProof

proc generateStorageProof*(
    state: StorageState, slotKey: UInt256
): StorageProof {.raises: [RlpError].} =
  let key = keccakHash(toBytesBE(slotKey)).data
  state.getBranch(key).StorageProof
