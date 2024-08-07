# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sugar, sequtils],
  chronos,
  eth/[common, trie, trie/db],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  ../../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../../../nimbus/common/chain_config,
  ../../network/history/[history_content, history_network],
  ../../network/state/[state_content, state_utils, state_network],
  ../../eth_data/yaml_utils,
  ../../database/content_db,
  ../test_helpers

export yaml_utils

const testVectorDir* = "./vendor/portal-spec-tests/tests/mainnet/state/validation/"

type
  YamlTrieNodeKV* = object
    state_root*: string
    content_key*: string
    content_value_offer*: string
    content_value_retrieval*: string

  YamlTrieNodeKVs* = seq[YamlTrieNodeKV]

  YamlContractBytecodeKV* = object
    state_root*: string
    content_key*: string
    content_value_offer*: string
    content_value_retrieval*: string

  YamlContractBytecodeKVs* = seq[YamlContractBytecodeKV]

func asNibbles*(key: openArray[byte], isEven = true): Nibbles =
  Nibbles.init(key, isEven)

func asTrieProof*(branch: openArray[seq[byte]]): TrieProof =
  TrieProof.init(branch.map(node => TrieNode.init(node)))

proc getTrieProof*(
    state: HexaryTrie, key: openArray[byte]
): TrieProof {.raises: [RlpError].} =
  let branch = state.getBranch(key)
  # for node in branch:
  #   debugEcho rlp.decode(node)
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
  var storageStates = Table[EthAddress, HexaryTrie]()

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

type StateNode* = ref object
  discoveryProtocol*: discv5_protocol.Protocol
  stateNetwork*: StateNetwork

proc newStateNode*(
    rng: ref HmacDrbgContext, port: int
): StateNode {.raises: [CatchableError].} =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new("", uint32.high, inMemory = true)
    sm = StreamManager.new(node)
    hn = HistoryNetwork.new(PortalNetwork.none, node, db, sm, FinishedAccumulator())
    sn =
      StateNetwork.new(PortalNetwork.none, node, db, sm, historyNetwork = Opt.some(hn))

  return StateNode(discoveryProtocol: node, stateNetwork: sn)

proc portalProtocol*(sn: StateNode): PortalProtocol =
  sn.stateNetwork.portalProtocol

proc localNode*(sn: StateNode): Node =
  sn.discoveryProtocol.localNode

proc start*(sn: StateNode) =
  sn.stateNetwork.start()

proc stop*(sn: StateNode) {.async.} =
  sn.stateNetwork.stop()
  await sn.discoveryProtocol.closeWait()

proc containsId*(sn: StateNode, contentId: ContentId): bool {.inline.} =
  return sn.stateNetwork.contentDB.get(contentId).isSome()

proc mockBlockHashToStateRoot*(
    sn: StateNode, blockHash: BlockHash, stateRoot: KeccakHash
) =
  let
    blockHeader = BlockHeader(stateRoot: stateRoot)
    headerRlp = rlp.encode(blockHeader)
    blockHeaderWithProof = BlockHeaderWithProof(
      header: ByteList[2048].init(headerRlp), proof: BlockHeaderProof.init()
    )
    contentKeyBytes = history_content.ContentKey
      .init(history_content.ContentType.blockHeader, blockHash)
      .encode()
    contentId = history_content.toContentId(contentKeyBytes)

  sn.portalProtocol().storeContent(
    contentKeyBytes, contentId, SSZ.encode(blockHeaderWithProof)
  )

proc waitUntilContentAvailable*(sn: StateNode, contentId: ContentId) {.async.} =
  var waitCount = 0
  while not sn.containsId(contentId):
    await sleepAsync(10.milliseconds)
    inc waitCount
    if waitCount > 1000:
      break
