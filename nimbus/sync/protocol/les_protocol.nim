# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[times, tables, options, sets, hashes, strutils],
  stew/shims/macros, chronicles, chronos, nimcrypto/[keccak, hash],
  eth/[rlp, keys, common],
  eth/p2p/[rlpx, kademlia, private/p2p_types],
  ./les/private/les_types, ./les/flow_control,
  ../types

export
  les_types

type
  ProofRequest* = object
    blockHash*: KeccakHash
    accountKey*: Blob
    key*: Blob
    fromLevel*: uint

  ContractCodeRequest* = object
    blockHash*: KeccakHash
    key*: EthAddress

  HelperTrieProofRequest* = object
    subType*: uint
    sectionIdx*: uint
    key*: Blob
    fromLevel*: uint
    auxReq*: uint

  LesStatus = object
    difficulty : DifficultyInt
    blockHash  : Hash256
    blockNumber: BlockNumber
    genesisHash: Hash256

const
  lesVersion = 2
  maxHeadersFetch = 192
  maxBodiesFetch = 32
  maxReceiptsFetch = 128
  maxCodeFetch = 64
  maxProofsFetch = 64
  maxHeaderProofsFetch = 64
  maxTransactionsFetch = 64

  # Handshake properties:
  # https://github.com/zsfelfoldi/go-ethereum/wiki/Light-Ethereum-Subprotocol-(LES)
  keyProtocolVersion = "protocolVersion"
    ## P: is 1 for the LPV1 protocol version.

  keyNetworkId = "networkId"
    ## P: should be 0 for testnet, 1 for mainnet.

  keyHeadTotalDifficulty = "headTd"
    ## P: Total Difficulty of the best chain.
    ## Integer, as found in block header.

  keyHeadHash = "headHash"
    ## B_32: the hash of the best (i.e. highest TD) known block.

  keyHeadNumber = "headNum"
    ## P: the number of the best (i.e. highest TD) known block.

  keyGenesisHash = "genesisHash"
    ## B_32: the hash of the Genesis block.

  #keyServeHeaders = "serveHeaders"
  #  ## (optional, no value)
  #  ## present if the peer can serve header chain downloads.

  keyServeChainSince = "serveChainSince"
    ## P (optional)
    ## present if the peer can serve Body/Receipts ODR requests
    ## starting from the given block number.

  keyServeStateSince = "serveStateSince"
    ## P (optional):
    ## present if the peer can serve Proof/Code ODR requests
    ## starting from the given block number.

  keyRelaysTransactions = "txRelay"
    ## (optional, no value)
    ## present if the peer can relay transactions to the ETH network.

  keyFlowControlBL = "flowControl/BL"
  keyFlowControlMRC = "flowControl/MRC"
  keyFlowControlMRR = "flowControl/MRR"
    ## see Client Side Flow Control:
    ## https://github.com/zsfelfoldi/go-ethereum/wiki/Client-Side-Flow-Control-model-for-the-LES-protocol

  keyAnnounceType = "announceType"
  keyAnnounceSignature = "sign"

proc getStatus(ctx: LesNetwork): LesStatus =
  discard

proc getBlockBodies(ctx: LesNetwork, hashes: openArray[Hash256]): seq[BlockBody] =
  discard

proc getBlockHeaders(ctx: LesNetwork, req: BlocksRequest): seq[BlockHeader] =
  discard

proc getReceipts(ctx: LesNetwork, hashes: openArray[Hash256]): seq[Receipt] =
  discard

proc getProofs(ctx: LesNetwork, proofs: openArray[ProofRequest]): seq[Blob] =
  discard

proc getContractCodes(ctx: LesNetwork, reqs: openArray[ContractCodeRequest]): seq[Blob] =
  discard

proc getHeaderProofs(ctx: LesNetwork, reqs: openArray[ProofRequest]): seq[Blob] =
  discard

proc getHelperTrieProofs(ctx: LesNetwork,
                          reqs: openArray[HelperTrieProofRequest],
                          outNodes: var seq[Blob], outAuxData: var seq[Blob]) =
  discard

proc getTransactionStatus(ctx: LesNetwork, txHash: KeccakHash): TransactionStatusMsg =
  discard

proc addTransactions(ctx: LesNetwork, transactions: openArray[Transaction]) =
  discard

proc initProtocolState(network: LesNetwork, node: EthereumNode) {.gcsafe.} =
  network.peers = initHashSet[LesPeer]()

proc addPeer(network: LesNetwork, peer: LesPeer) =
  network.enlistInFlowControl peer
  network.peers.incl peer

proc removePeer(network: LesNetwork, peer: LesPeer) =
  network.delistFromFlowControl peer
  network.peers.excl peer

template costQuantity(quantityExpr, max: untyped) {.pragma.}

proc getCostQuantity(fn: NimNode): tuple[quantityExpr, maxQuantity: NimNode] =
  # XXX: `getCustomPragmaVal` doesn't work yet on regular nnkProcDef nodes
  # (TODO: file as an issue)
  let costQuantity = fn.pragma.findPragma(bindSym"costQuantity")
  doAssert costQuantity != nil

  result.quantityExpr = costQuantity[1]
  result.maxQuantity= costQuantity[2]

  if result.maxQuantity.kind == nnkExprEqExpr:
    result.maxQuantity = result.maxQuantity[1]

macro outgoingRequestDecorator(n: untyped): untyped =
  result = n
  #let (costQuantity, maxQuantity) = n.getCostQuantity
  let (costQuantity, _) = n.getCostQuantity

  result.body.add quote do:
    trackOutgoingRequest(peer.networkState(les),
                         peer.state(les),
                         perProtocolMsgId, reqId, `costQuantity`)
  # echo result.repr

macro incomingResponseDecorator(n: untyped): untyped =
  result = n

  let trackingCall = quote do:
    trackIncomingResponse(peer.state(les), reqId, msg.bufValue)

  result.body.insert(n.body.len - 1, trackingCall)
  # echo result.repr

macro incomingRequestDecorator(n: untyped): untyped =
  result = n
  let (costQuantity, maxQuantity) = n.getCostQuantity

  template acceptStep(quantityExpr, maxQuantity) {.dirty.} =
    let requestCostQuantity = quantityExpr
    if requestCostQuantity > maxQuantity:
      await peer.disconnect(BreachOfProtocol)
      return

    let lesPeer = peer.state
    let lesNetwork = peer.networkState

    if not await acceptRequest(lesNetwork, lesPeer,
                               perProtocolMsgId,
                               requestCostQuantity): return

  result.body.insert(1, getAst(acceptStep(costQuantity, maxQuantity)))
  # echo result.repr

template updateBV: BufValueInt =
  bufValueAfterRequest(lesNetwork, lesPeer,
                       perProtocolMsgId, requestCostQuantity)

func getValue(values: openArray[KeyValuePair],
              key: string, T: typedesc): Option[T] =
  for v in values:
    if v.key == key:
      return some(rlp.decode(v.value, T))

func getRequiredValue(values: openArray[KeyValuePair],
                      key: string, T: typedesc): T =
  for v in values:
    if v.key == key:
      return rlp.decode(v.value, T)

  raise newException(HandshakeError,
                     "Required handshake field " & key & " missing")

p2pProtocol les(version = lesVersion,
                peerState = LesPeer,
                networkState = LesNetwork,
                outgoingRequestDecorator = outgoingRequestDecorator,
                incomingRequestDecorator = incomingRequestDecorator,
                incomingResponseThunkDecorator = incomingResponseDecorator):
  handshake:
    proc status(p: Peer, values: openArray[KeyValuePair])

  onPeerConnected do (peer: Peer):
    let
      network = peer.network
      lesPeer = peer.state
      lesNetwork = peer.networkState
      status  = lesNetwork.getStatus()

    template `=>`(k, v: untyped): untyped =
      KeyValuePair(key: k, value: rlp.encode(v))

    var lesProperties = @[
      keyProtocolVersion      => lesVersion,
      keyNetworkId            => network.networkId,
      keyHeadTotalDifficulty  => status.difficulty,
      keyHeadHash             => status.blockHash,
      keyHeadNumber           => status.blockNumber,
      keyGenesisHash          => status.genesisHash
    ]

    lesPeer.remoteReqCosts = currentRequestsCosts(lesNetwork, les.protocolInfo)

    if lesNetwork.areWeServingData:
      lesProperties.add [
        # keyServeHeaders       => nil,
        keyServeChainSince      => 0,
        keyServeStateSince      => 0,
        # keyRelaysTransactions => nil,
        keyFlowControlBL        => lesNetwork.bufferLimit,
        keyFlowControlMRR       => lesNetwork.minRechargingRate,
        keyFlowControlMRC       => lesPeer.remoteReqCosts
      ]

    if lesNetwork.areWeRequestingData:
      lesProperties.add(keyAnnounceType => lesNetwork.ourAnnounceType)

    let
      s = await peer.status(lesProperties, timeout = chronos.seconds(10))
      peerNetworkId   = s.values.getRequiredValue(keyNetworkId, NetworkId)
      peerGenesisHash = s.values.getRequiredValue(keyGenesisHash, KeccakHash)
      peerLesVersion = s.values.getRequiredValue(keyProtocolVersion, uint)

    template requireCompatibility(peerVar, localVar, varName: untyped) =
      if localVar != peerVar:
        raise newException(HandshakeError,
                           "Incompatibility detected! $1 mismatch ($2 != $3)" %
                           [varName, $localVar, $peerVar])

    requireCompatibility(peerLesVersion,  uint(lesVersion),  "les version")
    requireCompatibility(peerNetworkId,   network.networkId, "network id")
    requireCompatibility(peerGenesisHash, status.genesisHash, "genesis hash")

    template `:=`(lhs, key) =
      lhs = s.values.getRequiredValue(key, type(lhs))

    lesPeer.bestBlockHash := keyHeadHash
    lesPeer.bestBlockNumber := keyHeadNumber
    lesPeer.bestDifficulty := keyHeadTotalDifficulty

    let peerAnnounceType = s.values.getValue(keyAnnounceType, AnnounceType)
    if peerAnnounceType.isSome:
      lesPeer.isClient = true
      lesPeer.announceType = peerAnnounceType.get
    else:
      lesPeer.announceType = AnnounceType.Simple
      lesPeer.hasChainSince := keyServeChainSince
      lesPeer.hasStateSince := keyServeStateSince
      lesPeer.relaysTransactions := keyRelaysTransactions
      lesPeer.localFlowState.bufLimit := keyFlowControlBL
      lesPeer.localFlowState.minRecharge := keyFlowControlMRR
      lesPeer.localReqCosts := keyFlowControlMRC

    lesNetwork.addPeer lesPeer

  onPeerDisconnected do (peer: Peer, reason: DisconnectionReason) {.gcsafe.}:
    peer.networkState.removePeer peer.state

  ## Header synchronisation
  ##

  proc announce(
       peer: Peer,
       headHash: KeccakHash,
       headNumber: BlockNumber,
       headTotalDifficulty: DifficultyInt,
       reorgDepth: BlockNumber,
       values: openArray[KeyValuePair],
       announceType: AnnounceType) =

    if peer.state.announceType == AnnounceType.None:
      error "unexpected announce message", peer
      return

    if announceType == AnnounceType.Signed:
      let signature = values.getValue(keyAnnounceSignature, Blob)
      if signature.isNone:
        chronicles.error "missing announce signature"
        return
      let sig = Signature.fromRaw(signature.get).tryGet()
      let sigMsg = rlp.encodeList(headHash, headNumber, headTotalDifficulty)
      let signerKey = recover(sig, sigMsg).tryGet()
      if signerKey.toNodeId != peer.remote.id:
        chronicles.error "invalid announce signature"
        # TODO: should we disconnect this peer?
        return

    # TODO: handle new block

  requestResponse:
    proc getBlockHeaders(
           peer: Peer,
           req: BlocksRequest) {.
           costQuantity(req.maxResults.int, max = maxHeadersFetch).} =

      let ctx = peer.networkState()
      let headers = ctx.getBlockHeaders(req)
      await response.send(updateBV(), headers)

    proc blockHeaders(
           peer: Peer,
           bufValue: BufValueInt,
           blocks: openArray[BlockHeader])

  ## On-damand data retrieval
  ##

  requestResponse:
    proc getBlockBodies(
           peer: Peer,
           blocks: openArray[KeccakHash]) {.
           costQuantity(blocks.len, max = maxBodiesFetch), gcsafe.} =

      let ctx = peer.networkState()
      let blocks = ctx.getBlockBodies(blocks)
      await response.send(updateBV(), blocks)

    proc blockBodies(
           peer: Peer,
           bufValue: BufValueInt,
           bodies: openArray[BlockBody])

  requestResponse:
    proc getReceipts(
           peer: Peer,
           hashes: openArray[KeccakHash])
           {.costQuantity(hashes.len, max = maxReceiptsFetch).} =

      let ctx = peer.networkState()
      let receipts = ctx.getReceipts(hashes)
      await response.send(updateBV(), receipts)

    proc receipts(
           peer: Peer,
           bufValue: BufValueInt,
           receipts: openArray[Receipt])

  requestResponse:
    proc getProofs(
           peer: Peer,
           proofs: openArray[ProofRequest]) {.
           costQuantity(proofs.len, max = maxProofsFetch).} =

      let ctx = peer.networkState()
      let proofs = ctx.getProofs(proofs)
      await response.send(updateBV(), proofs)

    proc proofs(
           peer: Peer,
           bufValue: BufValueInt,
           proofs: openArray[Blob])

  requestResponse:
    proc getContractCodes(
           peer: Peer,
           reqs: seq[ContractCodeRequest]) {.
           costQuantity(reqs.len, max = maxCodeFetch).} =

      let ctx = peer.networkState()
      let results = ctx.getContractCodes(reqs)
      await response.send(updateBV(), results)

    proc contractCodes(
           peer: Peer,
           bufValue: BufValueInt,
           results: seq[Blob])

  nextID 15

  requestResponse:
    proc getHeaderProofs(
           peer: Peer,
           reqs: openArray[ProofRequest]) {.
           costQuantity(reqs.len, max = maxHeaderProofsFetch).} =

      let ctx = peer.networkState()
      let proofs = ctx.getHeaderProofs(reqs)
      await response.send(updateBV(), proofs)

    proc headerProofs(
           peer: Peer,
           bufValue: BufValueInt,
           proofs: openArray[Blob])

  requestResponse:
    proc getHelperTrieProofs(
           peer: Peer,
           reqs: openArray[HelperTrieProofRequest]) {.
           costQuantity(reqs.len, max = maxProofsFetch).} =

      let ctx = peer.networkState()
      var nodes, auxData: seq[Blob]
      ctx.getHelperTrieProofs(reqs, nodes, auxData)
      await response.send(updateBV(), nodes, auxData)

    proc helperTrieProofs(
           peer: Peer,
           bufValue: BufValueInt,
           nodes: seq[Blob],
           auxData: seq[Blob])

  ## Transaction relaying and status retrieval
  ##

  requestResponse:
    proc sendTxV2(
           peer: Peer,
           transactions: openArray[Transaction]) {.
           costQuantity(transactions.len, max = maxTransactionsFetch).} =

      let ctx = peer.networkState()

      var results: seq[TransactionStatusMsg]
      for t in transactions:
        let hash = t.rlpHash
        var s = ctx.getTransactionStatus(hash)
        if s.status == TransactionStatus.Unknown:
          ctx.addTransactions([t])
          s = ctx.getTransactionStatus(hash)

        results.add s

      await response.send(updateBV(), results)

    proc getTxStatus(
           peer: Peer,
           transactions: openArray[Transaction]) {.
           costQuantity(transactions.len, max = maxTransactionsFetch).} =

      let ctx = peer.networkState()

      var results: seq[TransactionStatusMsg]
      for t in transactions:
        results.add ctx.getTransactionStatus(t.rlpHash)
      await response.send(updateBV(), results)

    proc txStatus(
           peer: Peer,
           bufValue: BufValueInt,
           transactions: openArray[TransactionStatusMsg])

proc configureLes*(node: EthereumNode,
                   # Client options:
                   announceType = AnnounceType.Simple,
                   # Server options.
                   # The zero default values indicate that the
                   # LES server will be deactivated.
                   maxReqCount = 0,
                   maxReqCostSum = 0,
                   reqCostTarget = 0) =

  doAssert announceType != AnnounceType.Unspecified or maxReqCount > 0

  var lesNetwork = node.protocolState(les)
  lesNetwork.ourAnnounceType = announceType
  initFlowControl(lesNetwork, les.protocolInfo,
                  maxReqCount, maxReqCostSum, reqCostTarget)

proc configureLesServer*(node: EthereumNode,
                         # Client options:
                         announceType = AnnounceType.Unspecified,
                         # Server options.
                         # The zero default values indicate that the
                         # LES server will be deactivated.
                         maxReqCount = 0,
                         maxReqCostSum = 0,
                         reqCostTarget = 0) =
  ## This is similar to `configureLes`, but with default parameter
  ## values appropriate for a server.
  node.configureLes(announceType, maxReqCount, maxReqCostSum, reqCostTarget)

proc persistLesMessageStats*(node: EthereumNode) =
  persistMessageStats(node.protocolState(les))

