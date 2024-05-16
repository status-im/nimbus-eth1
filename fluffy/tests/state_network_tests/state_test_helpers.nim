# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sugar, sequtils],
  eth/[common, trie, trie/db],
  ../../nimbus/common/chain_config,
  ../../network/state/state_content

proc asNibbles*(key: openArray[byte], isEven = true): Nibbles =
  Nibbles.init(key, isEven)

proc asTrieProof*(branch: openArray[seq[byte]]): TrieProof =
  TrieProof.init(branch.map(node => TrieNode.init(node)))

proc getTrieProof*(
    state: HexaryTrie, key: openArray[byte]
): TrieProof {.raises: [RlpError].} =
  let branch = state.getBranch(key)
  branch.asTrieProof()

proc generateAccountProof*(
    state: HexaryTrie, address: EthAddress
): TrieProof {.raises: [RlpError].} =
  let key = keccakHash(address).data
  state.getTrieProof(key)

proc generateStorageProof*(
    state: HexaryTrie, slotKey: UInt256
): TrieProof {.raises: [RlpError].} =
  let key = keccakHash(toBytesBE(slotKey)).data
  state.getTrieProof(key)

proc getGenesisAlloc*(filePath: string): GenesisAlloc =
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  cn.genesis.alloc

proc toState*(
    alloc: GenesisAlloc
): (HexaryTrie, Table[EthAddress, HexaryTrie]) {.raises: [RlpError].} =
  var accountTrie = initHexaryTrie(newMemoryDB())
  var storageStates = initTable[EthAddress, HexaryTrie]()

  for address, genAccount in alloc:
    var storageRoot = EMPTY_ROOT_HASH
    var codeHash = EMPTY_CODE_HASH

    if genAccount.code.len() > 0:
      var storageTrie = initHexaryTrie(newMemoryDB())
      for slotKey, slotValue in genAccount.storage:
        let key = keccakHash(toBytesBE(slotKey)).data
        let value = rlp.encode(slotValue)
        storageTrie.put(key, value)
      storageStates[address] = storageTrie
      storageRoot = storageTrie.rootHash()
      codeHash = keccakHash(genAccount.code)

    let account = Account(
      nonce: genAccount.nonce,
      balance: genAccount.balance,
      storageRoot: storageRoot,
      codeHash: codeHash,
    )
    let key = keccakHash(address).data
    let value = rlp.encode(account)
    accountTrie.put(key, value)

  (accountTrie, storageStates)
