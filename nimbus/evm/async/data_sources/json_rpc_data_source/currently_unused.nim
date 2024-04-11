# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sequtils, typetraits, options, times, json],
  chronicles,
  chronos,
  nimcrypto,
  stint,
  stew/byteutils,
  json_rpc/rpcclient,
  eth/common,
  eth/rlp,
  eth/trie/hexary_proof_verification,
  eth/p2p,
  eth/p2p/rlpx,
  eth/p2p/private/p2p_types,
  #../../../sync/protocol,
  ../../../../db/[core_db, distinct_tries, incomplete_db, storage_types],
  ../../data_sources,
  ../../../../beacon/web3_eth_conv,
  web3/conversions,
  web3

when defined(legacy_eth66_enabled):
  from ../../../sync/protocol/eth66 import getNodeData

# Comment extracted from `json_rpc_data_source.nim` line 83
# ---------------------------------------------------------

proc parseBlockBodyAndFetchUncles(rpcClient: RpcClient, r: JsonNode): Future[BlockBody] {.async.} =
  var body: BlockBody
  for tn in r["transactions"].getElems:
    body.transactions.add(parseTransaction(tn))
  for un in r["uncles"].getElems:
    let uncleHash: Hash256 = un.getStr.ethHash
    let uncleHeader = await fetchBlockHeaderWithHash(rpcClient, uncleHash)
    body.uncles.add(uncleHeader)
  return body

proc fetchBlockHeaderAndBodyWithHash*(rpcClient: RpcClient, h: Hash256): Future[(BlockHeader, BlockBody)] {.async.} =
  let t0 = now()
  let r = request("eth_getBlockByHash", %[%h.prefixHex, %true], some(rpcClient))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  if r.kind == JNull:
    error "requested block not available", blockHash=h
    raise newException(ValueError, "Error when retrieving block header and body")
  let header = parseBlockHeader(r)
  let body = await parseBlockBodyAndFetchUncles(rpcClient, r)
  return (header, body)

proc fetchBlockHeaderAndBodyWithNumber*(rpcClient: RpcClient, n: BlockNumber): Future[(BlockHeader, BlockBody)] {.async.} =
  let t0 = now()
  let r = request("eth_getBlockByNumber", %[%n.prefixHex, %true], some(rpcClient))
  durationSpentDoingFetches += now() - t0
  fetchCounter += 1
  if r.kind == JNull:
    error "requested block not available", blockNumber=n
    raise newException(ValueError, "Error when retrieving block header and body")
  let header = parseBlockHeader(r)
  let body = await parseBlockBodyAndFetchUncles(rpcClient, r)
  return (header, body)


# Comment extracted from `json_rpc_data_source.nim` line 131
# ----------------------------------------------------------

const bytesLimit = 2 * 1024 * 1024
const maxNumberOfPeersToAttempt = 3

proc fetchUsingGetTrieNodes(peer: Peer, stateRoot: common.Hash256, paths: seq[SnapTriePaths]): Future[seq[seq[byte]]] {.async.} =
  let r = await peer.getTrieNodes(stateRoot, paths, bytesLimit)
  if r.isNone:
    raise newException(CatchableError, "AARDVARK: received None in GetTrieNodes response")
  else:
    return r.get.nodes

proc fetchUsingGetNodeData(peer: Peer, nodeHashes: seq[common.Hash256]): Future[seq[seq[byte]]] {.async.} =

  let r: Option[seq[seq[byte]]] = none[seq[seq[byte]]]() # AARDVARK await peer.getNodeData(nodeHashes)
  if r.isNone:
    raise newException(CatchableError, "AARDVARK: received None in GetNodeData response")
  else:
    echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fetchUsingGetNodeData received nodes: " & $(r.get.data)
    return r.get.data

  # AARDVARK whatever
  return @[]

proc findPeersAndMakeSomeCalls[R](peerPool: PeerPool, protocolName: string, protocolType: typedesc, initiateAttempt: (proc(p: Peer): Future[R] {.gcsafe, raises: [].})): Future[seq[Future[R]]] {.async.} =
  var attempts: seq[Future[R]]
  while true:
    #info("AARDVARK: findPeersAndMakeSomeCalls about to loop through the peer pool", count=peerPool.connectedNodes.len)
    for nodeOfSomeSort, peer in peerPool.connectedNodes:
      if peer.supports(protocolType):
        info("AARDVARK: findPeersAndMakeSomeCalls calling peer", protocolName, peer)
        attempts.add(initiateAttempt(peer))
        if attempts.len >= maxNumberOfPeersToAttempt:
          break
      #else:
      #  info("AARDVARK: peer does not support protocol", protocolName, peer)
    if attempts.len == 0:
      warn("AARDVARK: findPeersAndMakeSomeCalls did not find any peers; waiting and trying again", protocolName, totalPeerPoolSize=peerPool.connectedNodes.len)
      await sleepAsync(chronos.seconds(5))
    else:
      if attempts.len < maxNumberOfPeersToAttempt:
        warn("AARDVARK: findPeersAndMakeSomeCalls did not find enough peers, but found some", protocolName, totalPeerPoolSize=peerPool.connectedNodes.len, found=attempts.len)
      break
  return attempts

proc findPeersAndMakeSomeAttemptsToCallGetTrieNodes(peerPool: PeerPool, stateRoot: common.Hash256, paths: seq[SnapTriePaths]): Future[seq[Future[seq[seq[byte]]]]] =
  findPeersAndMakeSomeCalls(peerPool, "snap", protocol.snap, (proc(peer: Peer): Future[seq[seq[byte]]] = fetchUsingGetTrieNodes(peer, stateRoot, paths)))

proc findPeersAndMakeSomeAttemptsToCallGetNodeData(peerPool: PeerPool, stateRoot: Hash256, nodeHashes: seq[Hash256]): Future[seq[Future[seq[seq[byte]]]]] =
  findPeersAndMakeSomeCalls(peerPool, "eth66", eth66, (proc(peer: Peer): Future[seq[seq[byte]]] = fetchUsingGetNodeData(peer, nodeHashes)))

proc fetchNodes(peerPool: PeerPool, stateRoot: common.Hash256, paths: seq[SnapTriePaths], nodeHashes: seq[common.Hash256]): Future[seq[seq[byte]]] {.async.} =
  let attempts = await findPeersAndMakeSomeAttemptsToCallGetTrieNodes(peerPool, stateRoot, paths)
  #let attempts = await findPeersAndMakeSomeAttemptsToCallGetNodeData(peerPool, stateRoot, nodeHashes)
  let completedAttempt = await one(attempts)
  let nodes: seq[seq[byte]] = completedAttempt.read
  info("AARDVARK: fetchNodes received nodes", nodes)
  return nodes

# End
