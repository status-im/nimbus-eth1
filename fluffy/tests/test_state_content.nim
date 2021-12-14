# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, stew/byteutils,
  ../network/state/state_content

suite "State ContentKey Encodings":
  test "ContentKey - accountTrieNode":
    let path = ByteList.init(hexToSeqByte("0x0304"))
    var nodeHash: NodeHash
    nodeHash.data = hexToByteArray[sizeof(NodeHash)](
      "0x0100000000000000000000000000000000000000000000000000000000000000")
    let stateRoot = hexToByteArray[sizeof(Bytes32)](
      "0x0200000000000000000000000000000000000000000000000000000000000000")

    let accountTrieNodeKey = AccountTrieNodeKey(
      path: path, nodeHash: nodeHash, stateRoot: stateRoot)
    let contentKey = ContentKey(
      contentType: accountTrieNode, accountTrieNodeKey: accountTrieNodeKey)

    let encoded = encode(contentKey)
    check encoded.asSeq.toHex ==
      "0044000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000304"
    let decoded = decode(encoded)
    check decoded.isSome()

    let contentKeyDecoded = decoded.get()
    check:
      contentKeyDecoded.contentType == contentKey.contentType
      contentKeyDecoded.accountTrieNodeKey == contentKey.accountTrieNodeKey

      toContentId(contentKey).toHex() ==
        "17cc73bd15072a4f62fbec6e4dd0fa99bdc103e73b90143f01bb4079955ba74c"

# TODO: Add test for each ContentType, perhaps when path is specced out and
# test vectors exist.
