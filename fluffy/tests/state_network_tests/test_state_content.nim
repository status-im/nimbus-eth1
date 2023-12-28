# Fluffy
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, json, sequtils],
  testutils/unittests,
  stew/[byteutils, io2],
  eth/keys,
  ../../tools/state_bridge/state_bridge,
  ../../network/state/state_content

const testVectorDir =
  "./vendor/portal-spec-tests/tests/mainnet/state/"

procSuite "State Content":
  let rng = newRng()

  test "Encode/decode accountTrieProofKey":
    const
      address = "0x000d836201318ec6899a67540690382780743280"
      stateRoot = "0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"
      hexKey = "0x000d836201318ec6899a67540690382780743280d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"

    let
      addressBytes = hexToByteArray[20](address)
      stateRootBytes = hexToByteArray[sizeof(state_content.AccountTrieProofKey.stateRoot)](stateRoot)
      key = AccountTrieProofKey(address: addressBytes, stateRoot: stateRootBytes)

    let encodedKey = SSZ.encode(key)
    check encodedKey.to0xHex() == hexKey
    let decodedKey = decodeSsz(encodedKey, AccountTrieProofKey)
    check decodedKey.isOk()

  test "Encode/decode accountTrieProof itself":
    let file = testVectorDir & "/proofs.full.block.0.json"
    let content = readAllFile(file).valueOr:
      quit(1)

    let decoded =
      try:
        Json.decode(content, state_bridge.JsonProofVector)
      except SerializationError:
        quit(1)

    let proof = decoded.proofs[0].proof.map(hexToSeqByte)

    var accountTrieProof = AccountTrieProof(@[])
    for witness in proof:
      let witnessNode = ByteList(witness)
      discard accountTrieProof.add(witnessNode)

    let
      encodedProof = SSZ.encode(accountTrieProof)
      decodedProof = decodeSsz(encodedProof, AccountTrieProof).get()

    check decodedProof == accountTrieProof

