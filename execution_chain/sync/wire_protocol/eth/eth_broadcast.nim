# nimbus-execution-client
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, sets, times, random, math, sequtils],
  pkg/[chronos, chronicles, results],
  pkg/chronos/ratelimit,
  pkg/eth/common/[hashes, times],
  ../../../core/chain/forked_chain,
  ../../../core/pooled_txs_rlp,
  ../../../core/tx_pool,
  ../../../networking/p2p,
  ./[eth_requester, eth_types]

logScope:
  topics = "tx-broadcast"

const
  maxOperationQuota = 1000000
  fullReplenishTime = chronos.seconds(5)
  POOLED_STORAGE_TIME_LIMIT = initDuration(minutes = 20)
  cleanupTicker = chronos.minutes(5)
  # https://github.com/ethereum/devp2p/blob/b0c213de97978053a0f62c3ea4d23c0a3d8784bc/caps/eth.md#blockrangeupdate-0x11
  blockRangeUpdateTicker = chronos.minutes(2)
  SOFT_RESPONSE_LIMIT* = 2 * 1024 * 1024
  # https://github.com/ethereum/devp2p/blob/master/caps/eth.md#newpooledtransactionhashes-0x08
  MAX_TX_HASH_ANNOUNCE = 4096
  PENDING_TX_GOSSIP_MAX* = 2048
  txGossipDebounce = chronos.milliseconds(250)
  maxTxsPerFlush* = 256

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
  txPoolProcessCost = allowedOpsPerSecondCost(50_000)
  hashLookupCost = allowedOpsPerSecondCost(200_000)
  blockRangeUpdateCost = allowedOpsPerSecondCost(20)
  txGossipCost = allowedOpsPerSecondCost(200)

iterator peers69OrLater(wire: EthWireRef, random: bool = false): Peer =
  var peers = newSeqOfCap[Peer](wire.node.numPeers)
  for peer in wire.node.peers(eth71):
    if peer.isNil:
      continue
    peers.add peer
  for peer in wire.node.peers(eth70):
    if peer.isNil:
      continue
    peers.add peer
  for peer in wire.node.peers(eth69):
    if peer.isNil:
      continue
    peers.add peer
  if random:
    shuffle(peers)
  for peer in peers:
    if peer.connectionState != ConnectionState.Connected:
      continue
    yield peer

iterator ethPeers(wire: EthWireRef, random: bool = false): Peer =
  ## All connected eth peers regardless of version: the tx gossip
  ## messages (0x02, 0x08) are identical across eth68..71.
  var peers = newSeqOfCap[Peer](wire.node.numPeers)
  for peer in wire.node.peers(eth71):
    if peer.isNil:
      continue
    peers.add peer
  for peer in wire.node.peers(eth70):
    if peer.isNil:
      continue
    peers.add peer
  for peer in wire.node.peers(eth69):
    if peer.isNil:
      continue
    peers.add peer
  for peer in wire.node.peers(eth68):
    if peer.isNil:
      continue
    peers.add peer
  if random:
    shuffle(peers)
  for peer in peers:
    if peer.connectionState != ConnectionState.Connected:
      continue
    yield peer

proc markSeen(wire: EthWireRef, txHash: Hash32, peerId: NodeId) =
  wire.seenTransactions.withValue(txHash, seen):
    seen[].lastSeen = getTime()
    seen[].peers.incl(peerId)
  do:
    var peers = initHashSet[NodeId]()
    peers.incl(peerId)
    wire.seenTransactions[txHash] =
      SeenObject(lastSeen: getTime(), peers: peers)

proc syncerRunning*(wire: EthWireRef): bool =
  # Disable transactions gossip and processing when
  # the syncer is still busy
  const
    thresholdTime = 3 * 15

  let
    nowTime = EthTime.now()
    headerTime = wire.chain.latestHeader.timestamp

  let running = (nowTime - headerTime) > thresholdTime
  if running != not wire.gossipEnabled:
    wire.gossipEnabled = not running
    notice "Transaction broadcast state changed", enabled = wire.gossipEnabled

  running

proc handleTransactionsBroadcast*(wire: EthWireRef,
                                  packet: TransactionsPacket,
                                  peer: Peer) {.async: (raises: [CancelledError]).} =
  if wire.syncerRunning:
    return

  if packet.transactions.len == 0:
    return

  debug "Received new transactions",
    number = packet.transactions.len

  if wire.actionQueue.full:
    debug "Action queue full, dropping transaction broadcast",
      number = packet.transactions.len
    return

  wire.reqisterAction("TxPool consume incoming transactions"):
    for tx in packet.transactions:
      if tx.txType == TxEip4844:
        # Disallow blob transaction broadcast
        debug "Protocol Breach: Peer broadcast blob transaction",
          remote=peer.remote, clientId=peer.clientId
        await peer.disconnect(BreachOfProtocol, notifyRemote = true)
        return

      # Mark the sender before addTx: the pool's onAddedTx callback fires
      # synchronously inside addTx and the sender must already be excluded
      # from the rebroadcast.
      wire.markSeen(computeRlpHash(tx), peer.id)

      wire.txPool.addTx(tx).isOkOr:
        await sleepAsync(ZeroDuration)
        continue

      await sleepAsync(ZeroDuration)
      awaitQuota(wire, txPoolProcessCost, "adding into txpool")

proc peerById(wire: EthWireRef, id: NodeId): Peer =
  ## Resolve an announcing peer to a live handle. Peers still completing
  ## the rlpx handshake are acceptable fetch targets; only the dying
  ## states are excluded.
  for p in wire.node.peers():
    if not p.isNil and p.id == id and p.connectionState notin
        {ConnectionState.Disconnecting, ConnectionState.Disconnected}:
      return p
  nil

proc fetchPooledTxs(wire: EthWireRef, peer: Peer,
                    packet: NewPooledTransactionHashesPacket,
                    strictMeta = true)
    {.async: (raises: [CancelledError]).}

proc refetchFromAlternate*(wire: EthWireRef, failedId: NodeId,
                           packet: NewPooledTransactionHashesPacket)
    {.async: (raises: [CancelledError]).} =
  ## A fetch did not deliver these announced txs (dead peer, request error
  ## or protocol breach). Hand the not-yet-pooled hashes to another peer
  ## that announced them in the meantime; hashes with no alternate
  ## announcer are forgotten so a later announcement can retrigger a fetch.
  var
    retryTypes: seq[byte]
    retrySizes: seq[uint64]
    retryHashes: seq[Hash32]
    candidates: HashSet[NodeId]
  for i in 0 ..< packet.txHashes.len:
    let h = packet.txHashes[i]
    if h in wire.txPool:
      continue
    wire.seenTransactions.withValue(h, seen):
      seen[].peers.excl(failedId)
      candidates.incl(seen[].peers)
    retryTypes.add packet.txTypes[i]
    retrySizes.add packet.txSizes[i]
    retryHashes.add h

  if retryHashes.len == 0:
    return

  var alt: Peer = nil
  if candidates.len > 0:
    # An alternate announcer can still be mid-handshake and not yet
    # registered in the peer pool: poll briefly before giving up.
    for attempt in 0 ..< 20:
      for id in candidates:
        alt = wire.peerById(id)
        if not alt.isNil:
          break
      if not alt.isNil:
        break
      await sleepAsync(chronos.milliseconds(50))

  if alt.isNil:
    # Release the dedupe slots so a later announcement can retry.
    for h in retryHashes:
      wire.seenTransactions.del(h)
    return

  # The metadata carried here originates from the peer whose fetch just
  # failed (it may well be the lie that caused the failure), so the
  # alternate's response cannot be held to it: fetch without strict
  # size/type validation. Hash correspondence and blob/KZG validation
  # still apply.
  await wire.fetchPooledTxs(alt, NewPooledTransactionHashesPacket(
    txTypes: retryTypes,
    txSizes: retrySizes,
    txHashes: retryHashes,
  ), strictMeta = false)

proc fetchPooledTxs(wire: EthWireRef, peer: Peer,
                    packet: NewPooledTransactionHashesPacket,
                    strictMeta = true)
    {.async: (raises: [CancelledError]).} =
  ## Request the announced txs via GetPooledTransactions, validate them
  ## against the announcement and add them to the pool. `strictMeta`
  ## controls whether the announced type/size must match the delivered
  ## transactions; a refetch after a failed fetch only carries the failed
  ## peer's (untrustworthy) metadata and is validated leniently.
  # A peer can announce hashes right after the Status exchange, while rlpx
  # is still completing the remaining handshakes: `Connected` is only set
  # after all of them, so only bail out on states that cannot recover.
  if peer.connectionState in
      {ConnectionState.Disconnecting, ConnectionState.Disconnected}:
    await wire.refetchFromAlternate(peer.id, packet)
    return

  type
    SizeType = object
      size: uint64
      txType: byte

  let
    numTx = packet.txHashes.len

  var
    i = 0
    map: Table[Hash32, SizeType]

  while i < numTx:
    var
      msg: PooledTransactionsRequest
      res: Opt[PooledTransactionsPacket]
      sumSize = 0'u64

    while i < numTx:
      let size = packet.txSizes[i]
      if sumSize + size > SOFT_RESPONSE_LIMIT.uint64:
        if msg.txHashes.len == 0:
          # A single announced tx alone exceeds the response limit (an
          # oversized or lying announcement). Request it on its own rather
          # than breaking with an empty msg, which would leave `i`
          # un-advanced and spin this loop forever without ever awaiting.
          let txHash = packet.txHashes[i]
          if txHash notin wire.txPool:
            msg.txHashes.add txHash
            sumSize += size
            map[txHash] = SizeType(
              size: size,
              txType: packet.txTypes[i],
            )
          awaitQuota(wire, hashLookupCost, "check transaction exists in pool")
          inc i
        break

      let txHash = packet.txHashes[i]
      if txHash notin wire.txPool:
        msg.txHashes.add txHash
        sumSize += size
        map[txHash] = SizeType(
          size: size,
          txType: packet.txTypes[i],
        )

      awaitQuota(wire, hashLookupCost, "check transaction exists in pool")
      inc i

    if msg.txHashes.len == 0:
      continue

    if peer.connectionState in
        {ConnectionState.Disconnecting, ConnectionState.Disconnected}:
      await wire.refetchFromAlternate(peer.id, packet)
      return

    try:
      res = await peer.getPooledTransactions(msg)
    except EthP2PError as exc:
      debug "Request pooled transactions failed",
        msg=exc.msg
      await wire.refetchFromAlternate(peer.id, packet)
      return

    if res.isNone:
      debug "Request pooled transactions get nothing"
      for h in msg.txHashes:
        wire.seenTransactions.del(h)
      continue

    let
      ptx = res.get()

    for tx in ptx.transactions:
      # If we receive any blob transactions missing sidecars, or with
      # sidecars that don't correspond to the versioned hashes reported
      # in the header, disconnect from the sending peer.
      let
        size = getEncodedLength(tx)  # PooledTransacion: Transaction + blobsBundle size
        hash = computeRlpHash(tx.tx) # Only inner tx hash
      map.withValue(hash, val) do:
        if strictMeta and tx.tx.txType.byte != val.txType:
          debug "Protocol Breach: Received transaction with type differ from announced",
            remote=peer.remote, clientId=peer.clientId
          await peer.disconnect(BreachOfProtocol, notifyRemote = true)
          await wire.refetchFromAlternate(peer.id, packet)
          return

        # geth and Nethermind — two of the major clients — announce blob-tx
        # sizes computed without the EIP-7594 wrapper-version byte, one byte
        # short of the actual pooled encoding. Tolerating that off-by-one is
        # required to interoperate with their announcements instead of
        # treating them as a protocol breach.
        let sizeDelta = if size.uint64 >= val.size: size.uint64 - val.size
                        else: val.size - size.uint64
        if strictMeta and sizeDelta > 0 and
            (tx.tx.txType != TxEip4844 or sizeDelta > 1):
          debug "Protocol Breach: Received transaction with size differ from announced",
            remote=peer.remote, clientId=peer.clientId,
            announced=val.size, received=size
          await peer.disconnect(BreachOfProtocol, notifyRemote = true)
          await wire.refetchFromAlternate(peer.id, packet)
          return
      do:
        debug "Protocol Breach: Received transaction with hash differ from announced",
            remote=peer.remote, clientId=peer.clientId
        await peer.disconnect(BreachOfProtocol, notifyRemote = true)
        await wire.refetchFromAlternate(peer.id, packet)
        return

      if tx.tx.txType == TxEip4844 and tx.blobsBundle.isNil:
        debug "Protocol Breach: Received sidecar-less blob transaction",
          remote=peer.remote, clientId=peer.clientId
        await peer.disconnect(BreachOfProtocol, notifyRemote = true)
        await wire.refetchFromAlternate(peer.id, packet)
        return

      # addTx performs the expensive KZG verification itself; on
      # InvalidBlob we treat it as a protocol breach. Yield to the
      # event loop afterwards so RPC and peer dispatch aren't starved
      # during a large batch.
      wire.txPool.addTx(tx).isOkOr:
        if error == txErrorInvalidBlob:
          debug "Protocol Breach: Invalid blob transaction",
            remote=peer.remote, clientId=peer.clientId
          await peer.disconnect(BreachOfProtocol, notifyRemote = true)
          await wire.refetchFromAlternate(peer.id, packet)
          return
        await sleepAsync(ZeroDuration)
        continue

      await sleepAsync(ZeroDuration)
      awaitQuota(wire, txPoolProcessCost, "broadcast transactions hashes")

proc handleTxHashesBroadcast*(wire: EthWireRef,
                              packet: NewPooledTransactionHashesPacket,
                              peer: Peer) {.async: (raises: [CancelledError]).} =
  if wire.syncerRunning:
    return

  if packet.txHashes.len == 0:
    return

  debug "Received new pooled tx hashes",
    hashes = packet.txHashes.len

  if packet.txHashes.len != packet.txSizes.len or
     packet.txHashes.len != packet.txTypes.len:
    debug "Protocol Breach: new pooled tx hashes invalid params",
      hashes = packet.txHashes.len,
      sizes  = packet.txSizes.len,
      types  = packet.txTypes.len
    await peer.disconnect(BreachOfProtocol, notifyRemote = true)
    return

  # Cross-peer dedupe: drop hashes already in the pool or being fetched by
  # another in-flight action. The remaining (novel) hashes are the ones we
  # actually need to schedule a fetch for.
  let
    nowTime = getTime()
    peerId = peer.id
  var
    novelTypes: seq[byte]
    novelSizes: seq[uint64]
    novelHashes: seq[Hash32]
  for i in 0 ..< packet.txHashes.len:
    let h = packet.txHashes[i]
    if h in wire.txPool:
      continue
    wire.seenTransactions.withValue(h, seen):
      seen[].lastSeen = nowTime
      seen[].peers.incl(peerId)
      continue
    do:
      var peers = initHashSet[NodeId]()
      peers.incl(peerId)
      wire.seenTransactions[h] =
        SeenObject(lastSeen: nowTime, peers: peers)
      novelTypes.add packet.txTypes[i]
      novelSizes.add packet.txSizes[i]
      novelHashes.add h

  if novelHashes.len == 0:
    return

  if wire.actionQueue.full:
    debug "Action queue full, dropping tx hash announcement",
      hashes = novelHashes.len
    # Release dedupe slots so a later retry can proceed.
    for h in novelHashes:
      wire.seenTransactions.del(h)
    return

  let novelPacket = NewPooledTransactionHashesPacket(
    txTypes: novelTypes,
    txSizes: novelSizes,
    txHashes: novelHashes,
  )

  wire.reqisterAction("Handle broadcast transactions hashes"):
    await wire.fetchPooledTxs(peer, novelPacket)

proc cleanupSeenTransactions*(wire: EthWireRef) {.async: (raises: [CancelledError]).} =
  # Collect expired keys in a single synchronous pass. Do NOT await while
  # iterating the live table: a concurrently-dispatched handleTxHashesBroadcast
  # can insert into seenTransactions and trip Nim's "length of the table changed
  # while iterating over it" assertion.
  var expireds: seq[Hash32]
  let now = getTime()
  for key, seen in wire.seenTransactions:
    if now - seen.lastSeen > POOLED_STORAGE_TIME_LIMIT:
      expireds.add key

  # Deletion iterates over `expireds` (a seq), so awaiting here is safe even if
  # a concurrent handler mutates the table.
  for expire in expireds:
    wire.seenTransactions.del(expire)
    awaitQuota(wire, hashLookupCost, "broadcast transactions hashes")

proc queueTransactionGossip*(wire: EthWireRef, txHash: Hash32) {.raises: [].} =
  ## Synchronous and non-blocking: safe to invoke from inside `addTx`
  ## (this is the txPool.onAddedTx callback target).
  if wire.syncerRunning():
    return

  try:
    wire.pendingTxGossip.addLastNoWait(txHash)
  except AsyncQueueFullError:
    debug "Tx gossip queue full, dropping transaction", txHash

proc broadcastTransactions*(wire: EthWireRef, txHashes: seq[Hash32])
    {.async: (raises: [CancelledError]).} =
  # Resolve queued hashes to live pool items; txs mined or expired since
  # queuing are silently skipped.
  var items: seq[TxItemRef]
  for txHash in txHashes:
    let item = wire.txPool.getItem(txHash).valueOr:
      continue
    items.add item

  if items.len == 0:
    return

  let peers = toSeq(wire.ethPeers(random = true))
  if peers.len == 0:
    return

  # Spec: send full transactions to a small random subset of peers,
  # announce hashes to everyone else.
  let directCount = max(1, int(ceil(sqrt(float(peers.len)))))

  for i, peer in peers:
    if peer.connectionState != ConnectionState.Connected:
      continue

    let sendFull = i < directCount
    var
      fullTxs: seq[Transaction]
      fullHashes: seq[Hash32]
      fullBytes = 0
      annTypes: seq[byte]
      annSizes: seq[uint64]
      annHashes: seq[Hash32]

    for item in items:
      wire.seenTransactions.withValue(item.id, seen):
        if peer.id in seen[].peers:
          continue
      # Blob transactions are never sent in full (0x02), announce-only.
      # Cap the full-tx message size; overflow degrades to announcement.
      let txSize = getEncodedLength(item.tx)
      if sendFull and item.tx.txType != TxEip4844 and
         fullBytes + txSize <= SOFT_RESPONSE_LIMIT:
        fullTxs.add item.tx
        fullHashes.add item.id
        fullBytes += txSize
      else:
        annTypes.add item.tx.txType.byte
        # Announce the pooled encoding size (incl. blob sidecars): receivers
        # validate the announced size against the fetched PooledTransaction.
        annSizes.add uint64(getEncodedLength(item.pooledTx))
        annHashes.add item.id

    try:
      if fullTxs.len > 0:
        await peer.transactions(fullTxs)
        for h in fullHashes:
          wire.markSeen(h, peer.id)
        awaitQuota(wire, txGossipCost, "broadcast transactions")
      if annHashes.len > 0:
        await peer.newPooledTransactionHashes(annTypes, annSizes, annHashes)
        for h in annHashes:
          wire.markSeen(h, peer.id)
        awaitQuota(wire, txGossipCost, "announce tx hashes")
    except EthP2PError as exc:
      debug "Tx gossip to peer failed",
        remote=peer.remote, msg=exc.msg
      continue

    await sleepAsync(ZeroDuration)

proc txGossipLoop*(wire: EthWireRef) {.async: (raises: [CancelledError]).} =
  while true:
    # Sleep while idle, then debounce briefly so a burst of adds coalesces
    # into a single message per peer. Only debounce when the queue is empty:
    # under backlog the loop must flush back-to-back or a large batch
    # (e.g. 2000 txs) drains at just maxTxsPerFlush per debounce tick.
    var txHashes = @[await wire.pendingTxGossip.popFirst()]
    if wire.pendingTxGossip.len == 0:
      await sleepAsync(txGossipDebounce)
    while wire.pendingTxGossip.len > 0 and txHashes.len < maxTxsPerFlush:
      try:
        txHashes.add wire.pendingTxGossip.popFirstNoWait()
      except AsyncQueueEmptyError:
        break

    if wire.syncerRunning():
      continue

    await wire.broadcastTransactions(txHashes)

proc announcePooledTxsToPeer(wire: EthWireRef, peer: Peer)
    {.async: (raises: [CancelledError]).} =
  # The handshake handlers enqueue this before rlpx flips the peer to
  # `Connected`, so only bail out on states that cannot recover.
  if peer.connectionState in
      {ConnectionState.Disconnecting, ConnectionState.Disconnected}:
    return

  # Synchronous snapshot: no awaits while iterating the live pool table.
  var
    txTypes: seq[byte]
    txSizes: seq[uint64]
    txHashes: seq[Hash32]
  for item in wire.txPool.allItems:
    txTypes.add item.tx.txType.byte
    txSizes.add uint64(getEncodedLength(item.pooledTx))
    txHashes.add item.id

  var i = 0
  while i < txHashes.len:
    let j = min(i + MAX_TX_HASH_ANNOUNCE, txHashes.len)
    if peer.connectionState in
        {ConnectionState.Disconnecting, ConnectionState.Disconnected}:
      return
    try:
      await peer.newPooledTransactionHashes(
        txTypes[i..<j], txSizes[i..<j], txHashes[i..<j])
    except EthP2PError as exc:
      debug "Announce pool to new peer failed",
        remote=peer.remote, msg=exc.msg
      return
    for k in i ..< j:
      wire.markSeen(txHashes[k], peer.id)
    awaitQuota(wire, txGossipCost, "announce pool to new peer")
    i = j

proc scheduleTxAnnounceToNewPeer*(wire: EthWireRef, peer: Peer)
    {.async: (raises: [CancelledError]).} =
  if wire.syncerRunning():
    return
  if wire.txPool.len == 0:
    return
  if wire.actionQueue.full:
    debug "Action queue full, skipping tx announce to new peer"
    return

  wire.reqisterAction("Announce pooled txs to new peer"):
    await wire.announcePooledTxsToPeer(peer)

proc tickerLoop*(wire: EthWireRef) {.async: (raises: [CancelledError]).} =
  while true:
    # Create or replenish timer
    if wire.cleanupTimer.isNil or wire.cleanupTimer.finished:
      wire.cleanupTimer = sleepAsync(cleanupTicker)

    if wire.brUpdateTimer.isNil or wire.brUpdateTimer.finished:
      wire.brUpdateTimer = sleepAsync(blockRangeUpdateTicker)

    let
      res = await one(wire.cleanupTimer, wire.brUpdateTimer)

    if res == wire.cleanupTimer:
      wire.reqisterAction("Periodical cleanup"):
        await wire.cleanupSeenTransactions()

    if res == wire.brUpdateTimer:
      wire.reqisterAction("Periodical blockRangeUpdate"):
        let
          packet = BlockRangeUpdatePacket(
            earliest: 0,
            latest: wire.chain.latestNumber,
            latestHash: wire.chain.latestHash,
          )

        for peer in wire.peers69OrLater:
          try:
            await peer.blockRangeUpdate(packet)
          except EthP2PError as exc:
            debug "Broadcast block range update failed",
              msg=exc.msg
          awaitQuota(wire, blockRangeUpdateCost, "broadcast blockRangeUpdate")

proc setupTokenBucket*(): TokenBucket =
  TokenBucket.new(maxOperationQuota.int, fullReplenishTime)

proc actionLoop*(wire: EthWireRef) {.async: (raises: [CancelledError]).} =
  while true:
    let action = await wire.actionQueue.popFirst()
    await action()

proc stop*(wire: EthWireRef) {.async: (raises: [CancelledError]).} =
  # Detach the pool callback first so a late addTx cannot touch the
  # gossip queue while we are tearing down.
  if not wire.txPool.isNil:
    wire.txPool.onAddedTx = nil

  var waitedFutures = @[wire.tickerHeartbeat.cancelAndWait()]
  if not wire.txGossipHeartbeat.isNil:
    waitedFutures.add wire.txGossipHeartbeat.cancelAndWait()
  for fut in wire.actionHeartbeat:
    waitedFutures.add fut.cancelAndWait()

  let
    timeout = chronos.seconds(5)
    completed = await withTimeout(allFutures(waitedFutures), timeout)
  if not completed:
    trace "Broadcast.stop(): timeout reached", timeout
