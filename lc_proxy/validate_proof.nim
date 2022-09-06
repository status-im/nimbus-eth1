# light client proxy
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[sequtils, typetraits],
  stint,
  eth/common/eth_types as etypes,
  eth/common/eth_types_rlp,
  eth/rlp,
  eth/trie/hexary,
  web3/ethtypes

func toMDigest(arg: FixedBytes[32]): MDigest[256] =
  MDigest[256](data: distinctBase(arg))

proc isAccountProofValid*(
    stateRoot: FixedBytes[32],
    accountAddress: Address,
    accountBalance: UInt256,
    accountNonce: Quantity,
    accountCodeHash: CodeHash,
    accountStorageRootHash: StorageHash,
    mptNodes: seq[RlpEncodedBytes]
    ): bool =
  let
    mptNodesBytes = mptNodes.mapIt(distinctBase(it))
    keccakStateRootHash = toMDigest(stateRoot)
    acc = etypes.Account(
      nonce: distinctBase(accountNonce),
      balance: accountBalance,
      storageRoot: toMDigest(accountStorageRootHash),
      codeHash: toMDigest(accountCodeHash)
    )
    accountEncoded = rlp.encode(acc)
    accountKey = toSeq(keccakHash(distinctBase(accountAddress)).data)

  try:
    return isValidBranch(
      mptNodesBytes,
      keccakStateRootHash,
      accountKey,
      accountEncoded
    )
  except RlpError:
    return false

