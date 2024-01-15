# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import eth/[common, trie]


type
  AccountState* = distinct HexaryTrie
  StorageState* = distinct HexaryTrie

  MptProof* = seq[seq[byte]]
  AccountProof* = distinct MptProof
  StorageProof* = distinct MptProof

proc getBranch*(
    self: AccountState;
    key: openArray[byte]): seq[seq[byte]] {.borrow.}

proc rootHash*(self: AccountState): KeccakHash {.borrow.}

proc getBranch*(
    self: StorageState;
    key: openArray[byte]): seq[seq[byte]] {.borrow.}

proc rootHash*(self: StorageState): KeccakHash {.borrow.}

proc len*(self: AccountProof): int {.borrow.}

proc len*(self: StorageProof): int {.borrow.}