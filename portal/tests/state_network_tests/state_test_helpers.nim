# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sugar, sequtils],
  chronos,
  eth/[trie, trie/db],
  eth/common/[addresses, hashes, headers_rlp],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  eth/p2p/discoveryv5/routing_table,
  ../../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../../../execution_chain/common/chain_config,
  ../../network/legacy_history/[history_content, history_network, history_validation],
  ../../network/state/[state_content, state_utils, state_network],
  ../../eth_data/yaml_utils,
  ../../database/content_db,
  ../test_helpers

export yaml_utils

const testVectorDir* = "./vendor/portal-spec-tests/tests/mainnet/state/validation/"

type
  YamlTrieNodeKV* = object
    block_header*: string
    content_key*: string
    content_value_offer*: string
    content_value_retrieval*: string

  YamlTrieNodeKVs* = seq[YamlTrieNodeKV]

  YamlContractBytecodeKV* = object
    block_header*: string
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
    state: HexaryTrie, address: addresses.Address
): TrieProof {.raises: [RlpError].} =
  let key = keccak256(address.data).data
  state.getTrieProof(key)

proc generateStorageProof*(
    state: HexaryTrie, slotKey: UInt256
): TrieProof {.raises: [RlpError].} =
  let key = keccak256(toBytesBE(slotKey)).data
  state.getTrieProof(key)

proc getGenesisAlloc*(filePath: string): GenesisAlloc =
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  cn.genesis.alloc

proc toState*(
    alloc: GenesisAlloc
): (HexaryTrie, TableRef[addresses.Address, HexaryTrie]) {.raises: [RlpError].} =
  var accountTrie = initHexaryTrie(newMemoryDB())
  let storageStates = TableRef[addresses.Address, HexaryTrie]()

  for address, genAccount in alloc:
    var
      storageRoot = EMPTY_ROOT_HASH
      codeHash = EMPTY_CODE_HASH

    if genAccount.code.len() > 0:
      var storageTrie = initHexaryTrie(newMemoryDB())
      for slotKey, slotValue in genAccount.storage:
        let key = keccak256(toBytesBE(slotKey)).data
        storageTrie.put(key, rlp.encode(slotValue))

      storageStates[address] = storageTrie
      storageRoot = storageTrie.rootHash()
      codeHash = keccak256(genAccount.code)

    let account = Account(
      nonce: genAccount.nonce,
      balance: genAccount.balance,
      storageRoot: storageRoot,
      codeHash: codeHash,
    )
    accountTrie.put(keccak256(address.data).data, rlp.encode(account))

  (accountTrie, storageStates)

type StateNode* = ref object
  discv5*: discv5_protocol.Protocol
  stateNetwork*: StateNetwork

proc newStateNode*(
    rng: ref HmacDrbgContext, port: int
): StateNode {.raises: [CatchableError].} =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new(
      "", uint32.high, RadiusConfig(kind: Dynamic), node.localNode.id, inMemory = true
    )
    sm = StreamManager.new(node)
    hn = LegacyHistoryNetwork.new(
      PortalNetwork.none,
      node,
      db,
      sm,
      RuntimeConfig(),
      FinishedHistoricalHashesAccumulator(),
    )
    sn =
      StateNetwork.new(PortalNetwork.none, node, db, sm, historyNetwork = Opt.some(hn))

  return StateNode(discv5: node, stateNetwork: sn)

proc portalProtocol*(sn: StateNode): PortalProtocol =
  sn.stateNetwork.portalProtocol

proc localNode*(sn: StateNode): Node =
  sn.discv5.localNode

proc start*(sn: StateNode) =
  sn.stateNetwork.start()

proc stop*(sn: StateNode) {.async.} =
  discard sn.stateNetwork.stop()
  await sn.discv5.closeWait()

proc containsId*(sn: StateNode, contentId: ContentId): bool {.inline.} =
  # The contentKey parameter isn't used but is required for compatibility with
  # the dbContains handler
  return
    sn.stateNetwork.portalProtocol.dbContains(ContentKeyByteList.init(@[]), contentId)

proc mockStateRootLookup*(
    sn: StateNode, blockNumOrHash: uint64 | Hash32, stateRoot: Hash32
) =
  let
    blockHeader = Header(stateRoot: stateRoot)
    headerRlp = rlp.encode(blockHeader)
    blockHeaderWithProof = BlockHeaderWithProof(
      header: ByteList[MAX_HEADER_LENGTH].init(headerRlp),
      proof: ByteList[MAX_HEADER_PROOF_LENGTH].init(@[]),
    )
    contentKeyBytes = blockHeaderContentKey(blockNumOrHash).encode()
    contentId = history_content.toContentId(contentKeyBytes)

  sn.portalProtocol().storeContent(
    contentKeyBytes, contentId, SSZ.encode(blockHeaderWithProof), cacheContent = true
  )

proc waitUntilContentAvailable*(sn: StateNode, contentId: ContentId) {.async.} =
  var waitCount = 0
  while not sn.containsId(contentId):
    await sleepAsync(10.milliseconds)
    inc waitCount
    if waitCount > 1000:
      break
