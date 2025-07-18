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
  eth/common/times,
  results,
  ./types,
  ./requester,
  ../../networking/p2p,
  ../../core/tx_pool,
  ../../core/pooled_txs_rlp,
  ../../core/eip4844,
  ../../core/eip7594,
  ../../core/chain/forked_chain

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
  blockRangeUpdateCost = allowedOpsPerSecondCost(20)

iterator peers69OrLater(wire: EthWireRef, random: bool = false): Peer =
  var peers = newSeqOfCap[Peer](wire.node.numPeers)
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

  wire.reqisterAction("TxPool consume incoming transactions"):
    for tx in packet.transactions:
      if tx.txType == TxEip4844:
        # Disallow blob transaction broadcast
        debug "Protocol Breach: Peer broadcast blob transaction",
          remote=peer.remote, clientId=peer.clientId
        await peer.disconnect(BreachOfProtocol)
        return

      wire.txPool.addTx(tx).isOkOr:
        continue

      awaitQuota(wire, txPoolProcessCost, "adding into txpool")

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
    await peer.disconnect(BreachOfProtocol)
    return

  wire.reqisterAction("Handle broadcast transactions hashes"):
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

      try:
        res = await peer.getPooledTransactions(msg)
      except EthP2PError as exc:
        debug "Request pooled transactions failed",
          msg=exc.msg
        return

      if res.isNone:
        debug "Request pooled transactions get nothing"
        return

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
          if tx.tx.txType.byte != val.txType:
            debug "Protocol Breach: Received transaction with type differ from announced",
              remote=peer.remote, clientId=peer.clientId
            await peer.disconnect(BreachOfProtocol)
            return

          if size.uint64 != val.size:
            debug "Protocol Breach: Received transaction with size differ from announced",
              remote=peer.remote, clientId=peer.clientId
            await peer.disconnect(BreachOfProtocol)
            return
        do:
          debug "Protocol Breach: Received transaction with hash differ from announced",
              remote=peer.remote, clientId=peer.clientId
          await peer.disconnect(BreachOfProtocol)
          return

        if tx.tx.txType == TxEip4844:
          if tx.blobsBundle.isNil:
            debug "Protocol Breach: Received sidecar-less blob transaction",
              remote=peer.remote, clientId=peer.clientId
            await peer.disconnect(BreachOfProtocol)
            return

          if tx.blobsBundle.wrapperVersion == WrapperVersionEIP4844:
            validateBlobTransactionWrapper4844(tx).isOkOr:
              debug "Protocol Breach: EIP-4844 sidecar validation error", msg=error,
                remote=peer.remote, clientId=peer.clientId
              await peer.disconnect(BreachOfProtocol)
              return

          if tx.blobsBundle.wrapperVersion == WrapperVersionEIP7594:
            validateBlobTransactionWrapper7594(tx).isOkOr:
              debug "Protocol Breach: EIP-7594 sidecar validation error", msg=error,
                remote=peer.remote, clientId=peer.clientId
              await peer.disconnect(BreachOfProtocol)
              return

        wire.txPool.addTx(tx).isOkOr:
          continue

        awaitQuota(wire, txPoolProcessCost, "broadcast transactions hashes")

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
        var expireds: seq[Hash32]
        for key, seen in wire.seenTransactions:
          if getTime() - seen.lastSeen > POOLED_STORAGE_TIME_LIMIT:
            expireds.add key
          awaitQuota(wire, hashLookupCost, "broadcast transactions hashes")

        for expire in expireds:
          wire.seenTransactions.del(expire)
          awaitQuota(wire, hashLookupCost, "broadcast transactions hashes")

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
  var waitedFutures = @[
    wire.tickerHeartbeat.cancelAndWait(),
    wire.actionHeartbeat.cancelAndWait(),
  ]

  let
    timeout = chronos.seconds(5)
    completed = await withTimeout(allFutures(waitedFutures), timeout)
  if not completed:
    trace "Broadcast.stop(): timeout reached", timeout,
      futureErrors = waitedFutures.filterIt(it.error != nil).mapIt(it.error.msg)
