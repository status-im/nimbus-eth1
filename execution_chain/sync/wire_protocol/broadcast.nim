# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, sets, times, sequtils, random],
  chronos,
  chronos/ratelimit,
  chronicles,
  eth/common/hashes,
  stew/assign2,
  results,
  ./types,
  ./requester,
  ../../networking/p2p,
  ../../core/tx_pool,
  ../../core/eip4844

logScope:
  topics = "tx-broadcast"

const
  maxOperationQuota = 1000000
  fullReplenishTime = chronos.seconds(5)
  NUM_PEERS_REBROADCAST_QUOTIENT = 4
  POOLED_STORAGE_TIME_LIMIT = initDuration(minutes = 20)
  cleanupTicker = chronos.minutes(5)

template awaitQuota(bcParam: EthWireRef, costParam: float, protocolIdParam: string) =
  let
    wire = bcParam
    cost = int(costParam)
    protocolId = protocolIdParam

  try:
    if not wire.quota.tryConsume(cost):
      debug "Awaiting broadcast quota", cost = cost, protocolId = protocolId
      await wire.quota.consume(cost)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    debug "Error while waiting broadcast quota",
      cost = cost, protocolId = protocolId, msg = exc.msg

template reqisterAction(wire: EthWireRef, actionDesc: string, body) =
  block:
    proc actionHandler(): Future[void] {.async: (raises: [CancelledError]).} =
      debug "Invoking broadcast action", desc=actionDesc
      body

    await wire.actionQueue.addLast(actionHandler)

func allowedOpsPerSecondCost(n: int): float =
  const replenishRate = (maxOperationQuota / fullReplenishTime.nanoseconds.float)
  (replenishRate * 1000000000'f / n.float)

const
  txPoolProcessCost = allowedOpsPerSecondCost(1000)
  hashLookupCost = allowedOpsPerSecondCost(2000)
  hashingCost = allowedOpsPerSecondCost(5000)

func add(seen: SeenObject, peer: Peer) =
  seen.peers.incl(peer.id)

proc seenByPeer(wire: EthWireRef,
                packet: NewPooledTransactionHashesPacket,
                peer: Peer) {.async: (raises: [CancelledError]).} =
  for hash in packet.txHashes:
    var seen = wire.seenTransactions.getOrDefault(hash, nil)
    if seen.isNil:
      seen = SeenObject(
        lastSeen: getTime(),
      )
      seen.add peer
      wire.seenTransactions[hash] = seen
    else:
      seen.add peer

    awaitQuota(wire, hashLookupCost, "seen by peer")

proc broadcastTransactions(wire: EthWireRef,
                           packet: TransactionsPacket,
                           hashes: NewPooledTransactionHashesPacket ,
                           peer: Peer) {.async: (raises: [CancelledError]).} =
  # This is used to avoid re-sending along newPooledTransactionHashes
  # announcements/re-broadcasts

  var msg = newSeqOfCap[Transaction](packet.transactions.len)
  for i, hash in hashes.txHashes:
    var seen = wire.seenTransactions.getOrDefault(hash, nil)
    if seen.isNil:
      seen = SeenObject(
        lastSeen: getTime(),
      )
      seen.add peer
      wire.seenTransactions[hash] = seen
      msg.add packet.transactions[i]
    elif peer.id notin seen.peers:
      seen.add peer
      msg.add packet.transactions[i]

    awaitQuota(wire, hashLookupCost, "broadcast transactions")

  try:
    await peer.transactions(msg)
  except EthP2PError as exc:
    debug "broadcast transactions failed",
      msg=exc.msg

proc prepareTxHashesAnnouncement(wire: EthWireRef, packet: TransactionsPacket):
                                   Future[NewPooledTransactionHashesPacket]
                                     {.async: (raises: [CancelledError]).} =
  let len = packet.transactions.len
  var ann = NewPooledTransactionHashesPacket(
    txTypes : newSeqOfCap[byte](len),
    txSizes : newSeqOfCap[uint64](len),
    txHashes: newSeqOfCap[Hash32](len),
  )
  for tx in packet.transactions:
    let (size, hash) = getEncodedLengthAndHash(tx)
    ann.txTypes.add tx.txType.byte
    ann.txSizes.add size.uint64
    ann.txHashes.add hash

    awaitQuota(wire, hashingCost, "broadcast transactions")

  ann

proc broadcastTxHashes(wire: EthWireRef,
                       hashes: NewPooledTransactionHashesPacket,
                       peer: Peer) {.async: (raises: [CancelledError]).} =
  let len = hashes.txHashes.len
  var msg = NewPooledTransactionHashesPacket(
    txTypes : newSeqOfCap[byte](len),
    txSizes : newSeqOfCap[uint64](len),
    txHashes: newSeqOfCap[Hash32](len),
  )

  template copyFrom(msg, hashes, i) =
    msg.txTypes.add hashes.txTypes[i]
    msg.txSizes.add hashes.txSizes[i]
    msg.txHashes.add hashes.txHashes[i]

  for i, hash in hashes.txHashes:
    var seen = wire.seenTransactions.getOrDefault(hash, nil)
    if seen.isNil:
      seen = SeenObject(
        lastSeen: getTime(),
      )
      seen.add peer
      wire.seenTransactions[hash] = seen
      msg.copyFrom(hashes, i)
    elif peer.id notin seen.peers:
      seen.add peer
      msg.copyFrom(hashes, i)

    awaitQuota(wire, hashLookupCost, "broadcast transactions hashes")

  try:
    await peer.newPooledTransactionHashes(msg.txTypes, msg.txSizes, msg.txHashes)
  except EthP2PError as exc:
    debug "broadcast tx hashes failed",
      msg=exc.msg

proc handleTransactionsBroadcast*(wire: EthWireRef,
                                  packet: TransactionsPacket,
                                  peer: Peer) {.async: (raises: [CancelledError]).} =
  if packet.transactions.len == 0:
    return

  debug "received new transactions",
    number = packet.transactions.len

  # Don't rebroadcast invalid transactions
  let newPacket = TransactionsPacket(
    transactions: newSeqOfCap[Transaction](packet.transactions.len)
  )

  wire.reqisterAction("TxPool consume incoming transactions"):
    for tx in packet.transactions:
      if tx.txType == TxEip4844:
        # Disallow blob transaction broadcast
        await peer.disconnect(ClientQuitting)
        return

      wire.txPool.addTx(tx).isOkOr:
        continue

      # Only rebroadcast good transactions
      newPacket.transactions.add tx
      awaitQuota(wire, txPoolProcessCost, "adding into txpool")

  wire.reqisterAction("Broadcast transactions or hashes"):
    let hashes = await wire.prepareTxHashesAnnouncement(newPacket)
    await wire.seenByPeer(hashes, peer)

    let
      numPeers = wire.node.numPeers
      maxPeers = max(1, numPeers div NUM_PEERS_REBROADCAST_QUOTIENT)

    var
      i = 0
      peers = newSeqOfCap[Peer](numPeers)

    for peer in wire.node.peers:
      if peer.isNil:
        continue

      if peer.supports(eth68) or peer.supports(eth69):
        peers.add peer

    shuffle(peers)

    for peer in peers:
      if peer.connectionState != ConnectionState.Connected:
        continue

      if i < maxPeers:
        await wire.broadcastTransactions(newPacket, hashes, peer)
      else:
        await wire.broadcastTxHashes(hashes, peer)
      inc i

proc handleTxHashesBroadcast*(wire: EthWireRef,
                              packet: NewPooledTransactionHashesPacket,
                              peer: Peer) {.async: (raises: [CancelledError]).} =
  if packet.txHashes.len == 0:
    return

  debug "received new pooled tx hashes",
    hashes = packet.txHashes.len

  if packet.txHashes.len != packet.txSizes.len or
     packet.txHashes.len != packet.txTypes.len:
    debug "new pooled tx hashes invalid params",
      hashes = packet.txHashes.len,
      sizes  = packet.txSizes.len,
      types  = packet.txTypes.len
    return

  wire.reqisterAction("Broadcast transactions hashes"):
    await wire.seenByPeer(packet, peer)
    var
      msg: PooledTransactionsRequest
      res: Opt[PooledTransactionsPacket]

    assign(msg.txHashes, packet.txHashes)

    try:
      res = await peer.getPooledTransactions(msg)
    except EthP2PError as exc:
      debug "request pooled transactions failed",
        msg=exc.msg

    if res.isNone:
      debug "request pooled transactions get nothing"
      return

    let
      ptx = res.get()
      len = ptx.transactions.len

    var hashes = NewPooledTransactionHashesPacket(
      txTypes : newSeqOfCap[byte](len),
      txSizes : newSeqOfCap[uint64](len),
      txHashes: newSeqOfCap[Hash32](len),
    )

    for i, tx in ptx.transactions:
      # If we receive any blob transactions missing sidecars, or with
      # sidecars that don't correspond to the versioned hashes reported
      # in the header, disconnect from the sending peer.
      if tx.tx.txType == TxEip4844:
        if tx.networkPayload.isNil:
          debug "Received sidecar-less blob transaction", peer
          await peer.disconnect(ClientQuitting)
          return
        validateBlobTransactionWrapper(tx).isOkOr:
          debug "Sidecar validation error", msg=error
          await peer.disconnect(ClientQuitting)
          return

      wire.txPool.addTx(tx).isOkOr:
        continue

      # TODO: What if peer give us scrambled order of transactions?
      # maybe need some hash map?
      hashes.txTypes.add packet.txTypes[i]
      hashes.txSizes.add packet.txSizes[i]
      hashes.txHashes.add packet.txHashes[i]

      awaitQuota(wire, txPoolProcessCost, "broadcast transactions hashes")

    var peers = newSeqOfCap[Peer](wire.node.numPeers)
    for peer in wire.node.peers:
      if peer.isNil:
        continue

      if peer.supports(eth68) or peer.supports(eth69):
        peers.add peer

    for peer in peers:
      if peer.connectionState != ConnectionState.Connected:
        continue

      await wire.broadcastTxHashes(hashes, peer)

proc setupCleanup*(wire: EthWireRef) {.async: (raises: [CancelledError]).} =
  while true:
    await sleepAsync(cleanupTicker)

    wire.reqisterAction("Periodical cleanup"):
      var expireds: seq[Hash32]
      for key, seen in wire.seenTransactions:
        if getTime() - seen.lastSeen > POOLED_STORAGE_TIME_LIMIT:
          expireds.add key
        awaitQuota(wire, hashLookupCost, "broadcast transactions hashes")

      for expire in expireds:
        wire.seenTransactions.del(expire)
        awaitQuota(wire, hashLookupCost, "broadcast transactions hashes")

proc setupTokenBucket*(): TokenBucket =
  TokenBucket.new(maxOperationQuota.int, fullReplenishTime)

proc setupAction*(wire: EthWireRef) {.async: (raises: [CancelledError]).} =
  while true:
    let action = await wire.actionQueue.popFirst()
    await action()

proc stop*(wire: EthWireRef) {.async: (raises: [CancelledError]).} =
  var waitedFutures = @[
    wire.cleanupHeartbeat.cancelAndWait(),
    wire.actionHeartbeat.cancelAndWait(),
  ]

  let
    timeout = chronos.seconds(5)
    completed = await withTimeout(allFutures(waitedFutures), timeout)
  if not completed:
    trace "Broadcast.stop(): timeout reached", timeout,
      futureErrors = waitedFutures.filterIt(it.error != nil).mapIt(it.error.msg)
