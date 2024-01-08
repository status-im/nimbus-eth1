# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, json, sequtils],
  testutils/unittests,
  stew/[byteutils, io2],
  eth/keys,
  ../../network/state/state_content

const testVectorDir =
  "./vendor/portal-spec-tests/tests/mainnet/state/"

procSuite "State Content":
  let rng = newRng()

  test "Encode/decode accountTrieProof":
    let file = testVectorDir & "/proofs.full.block.0.json"
    let content = readAllFile(file).valueOr:
      quit(1)

    let decoded =
      try:
        Json.decode(content, state_content.JsonProofVector)
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

