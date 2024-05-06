# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import eth/common, ./state_content

proc validateAccountTrieNodeHash*(
    accountTrieNodeKey: AccountTrieNodeKey, accountTrieNode: AccountTrieNodeRetrieval
): bool =
  let expectedHash = accountTrieNodeKey.nodeHash
  let actualHash = keccakHash(accountTrieNode.node.asSeq())

  expectedHash == actualHash

proc validateContractTrieNodeHash*(
    contractTrieNodeKey: ContractTrieNodeKey,
    contractTrieNode: ContractTrieNodeRetrieval,
): bool =
  let expectedHash = contractTrieNodeKey.nodeHash
  let actualHash = keccakHash(contractTrieNode.node.asSeq())

  expectedHash == actualHash

proc validateContractCodeHash*(
    contractCodeKey: ContractCodeKey, contractCode: ContractCodeRetrieval
): bool =
  let expectedHash = contractCodeKey.codeHash
  let actualHash = keccakHash(contractCode.code.asSeq())

  expectedHash == actualHash
