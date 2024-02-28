# Nimbus - Portal Network
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/net,
  eth/[common, keys, rlp, trie, trie/db],
  eth/p2p/discoveryv5/[enr, node, routing_table],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../network/history/[accumulator, history_content],
  ../network/state/experimental/state_proof_types,
  ../../nimbus/db/core_db,
  ../../nimbus/common/[chain_config],
  ../database/content_db

proc localAddress*(port: int): Address {.raises: [ValueError].} =
  Address(ip: parseIpAddress("127.0.0.1"), port: Port(port))

proc initDiscoveryNode*(
    rng: ref HmacDrbgContext,
    privKey: PrivateKey,
    address: Address,
    bootstrapRecords: openArray[Record] = [],
    localEnrFields: openArray[(string, seq[byte])] = [],
    previousRecord = none[enr.Record](),
): discv5_protocol.Protocol {.raises: [CatchableError].} =
  # set bucketIpLimit to allow bucket split
  let config = DiscoveryConfig.init(1000, 24, 5)

  result = newProtocol(
    privKey,
    some(address.ip),
    some(address.port),
    some(address.port),
    bindPort = address.port,
    bootstrapRecords = bootstrapRecords,
    localEnrFields = localEnrFields,
    previousRecord = previousRecord,
    config = config,
    rng = rng,
  )

  result.open()

proc genByteSeq*(length: int): seq[byte] =
  var i = 0
  var resultSeq = newSeq[byte](length)
  while i < length:
    resultSeq[i] = byte(i)
    inc i
  return resultSeq

func buildAccumulator*(headers: seq[BlockHeader]): Result[FinishedAccumulator, string] =
  var accumulator: Accumulator
  for header in headers:
    updateAccumulator(accumulator, header)

    if header.blockNumber.truncate(uint64) == mergeBlockNumber - 1:
      return ok(finishAccumulator(accumulator))

  err("Not enough headers provided to finish the accumulator")

func buildAccumulatorData*(
    headers: seq[BlockHeader]
): Result[(FinishedAccumulator, seq[EpochAccumulator]), string] =
  var accumulator: Accumulator
  var epochAccumulators: seq[EpochAccumulator]
  for header in headers:
    updateAccumulator(accumulator, header)

    if accumulator.currentEpoch.len() == epochSize:
      epochAccumulators.add(accumulator.currentEpoch)

    if header.blockNumber.truncate(uint64) == mergeBlockNumber - 1:
      epochAccumulators.add(accumulator.currentEpoch)

      return ok((finishAccumulator(accumulator), epochAccumulators))

  err("Not enough headers provided to finish the accumulator")

func buildProof*(
    header: BlockHeader, epochAccumulators: seq[EpochAccumulator]
): Result[AccumulatorProof, string] =
  let epochIndex = getEpochIndex(header)
  doAssert(epochIndex < uint64(epochAccumulators.len()))
  let epochAccumulator = epochAccumulators[epochIndex]

  buildProof(header, epochAccumulator)

func buildHeaderWithProof*(
    header: BlockHeader, epochAccumulators: seq[EpochAccumulator]
): Result[BlockHeaderWithProof, string] =
  ## Construct the accumulator proof for a specific header.
  ## Returns the block header with the proof
  if header.isPreMerge():
    let epochIndex = getEpochIndex(header)
    doAssert(epochIndex < uint64(epochAccumulators.len()))
    let epochAccumulator = epochAccumulators[epochIndex]

    buildHeaderWithProof(header, epochAccumulator)
  else:
    err("Cannot build accumulator proof for post merge header")

func buildHeadersWithProof*(
    headers: seq[BlockHeader], epochAccumulators: seq[EpochAccumulator]
): Result[seq[BlockHeaderWithProof], string] =
  var headersWithProof: seq[BlockHeaderWithProof]
  for header in headers:
    headersWithProof.add(?buildHeaderWithProof(header, epochAccumulators))

  ok(headersWithProof)

proc getGenesisAlloc*(filePath: string): GenesisAlloc =
  var cn: NetworkParams
  if not loadNetworkParams(filePath, cn):
    quit(1)

  cn.genesis.alloc

proc toState*(
    alloc: GenesisAlloc
): (AccountState, Table[EthAddress, StorageState]) {.raises: [RlpError].} =
  var accountTrie = initHexaryTrie(newMemoryDB())
  var storageStates = initTable[EthAddress, StorageState]()

  for address, genAccount in alloc:
    var storageRoot = EMPTY_ROOT_HASH
    var codeHash = EMPTY_CODE_HASH

    if genAccount.code.len() > 0:
      var storageTrie = initHexaryTrie(newMemoryDB())
      for slotKey, slotValue in genAccount.storage:
        let key = keccakHash(toBytesBE(slotKey)).data
        let value = rlp.encode(slotValue)
        storageTrie.put(key, value)
      storageStates[address] = storageTrie.StorageState
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

  (accountTrie.AccountState, storageStates)
