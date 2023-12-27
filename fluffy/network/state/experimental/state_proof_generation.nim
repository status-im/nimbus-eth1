# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stint,
  eth/[common, trie],
  ./state_proof_types


proc generateAccountProof*(
    state: AccountState,
    address: EthAddress): AccountProof {.raises: [RlpError].} =
  let key = keccakHash(address).data
  state.getBranch(key).AccountProof

proc generateStorageProof*(
    state: StorageState,
    slotKey: UInt256): StorageProof {.raises: [RlpError].} =
  let key = keccakHash(toBytesBE(slotKey)).data
  state.getBranch(key).StorageProof

# We might want to use these procs below for interim nodes.
# Supplying a partial key will give all the trie nodes leading up to the key.
# To generate a partial key, hash the full account address or slotKey then truncate it.
# Supplying an empty string as the key will return the root node.
# Avoid using unless required.
# It's not yet clear to me how we can verify these interim nodes because
# they will return as a MissingKey result in the proof verification.
proc generateAccountProof*(
    state: AccountState,
    key: openArray[byte]): AccountProof {.raises: [RlpError].} =
  state.getBranch(key).AccountProof

proc generateStorageProof*(
    state: StorageState,
    key: openArray[byte]): StorageProof {.raises: [RlpError].} =
  state.getBranch(key).StorageProof


