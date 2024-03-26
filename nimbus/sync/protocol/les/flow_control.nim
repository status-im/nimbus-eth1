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
  std/[tables, sets],
  chronicles, chronos,
  eth/[rlp, common],
  eth/p2p/[rlpx, private/p2p_types],
  ./private/les_types

const
  maxSamples = 100000
  rechargingScale = 1000000

  lesStatsKey = "les.flow_control.stats"
  lesStatsVer = 0

logScope:
  topics = "les flow_control"

# TODO: move this somewhere
proc pop[A, B](t: var Table[A, B], key: A): B =
  result = t[key]
  t.del(key)

when LesTime is SomeInteger:
  template `/`(lhs, rhs: LesTime): LesTime =
    lhs div rhs

when defined(testing):
  var lesTime* = LesTime(0)
  template now(): LesTime = lesTime
  template advanceTime(t) = lesTime += LesTime(t)

else:
  import times
  let startTime = epochTime()

  proc now(): LesTime =
    return LesTime((times.epochTime() - startTime) * 1000.0)

proc addSample(ra: var StatsRunningAverage; x, y: float64) =
  if ra.count >= maxSamples:
    let decay = float64(ra.count + 1 - maxSamples) / maxSamples
    template applyDecay(x) = x -= x * decay

    applyDecay ra.sumX
    applyDecay ra.sumY
    applyDecay ra.sumXX
    applyDecay ra.sumXY
    ra.count = maxSamples - 1

  inc ra.count
  ra.sumX += x
  ra.sumY += y
  ra.sumXX += x * x
  ra.sumXY += x * y

proc calc(ra: StatsRunningAverage): tuple[m, b: float] =
  if ra.count == 0:
    return

  let count = float64(ra.count)
  let d = count * ra.sumXX - ra.sumX * ra.sumX
  if d < 0.001:
    return (m: ra.sumY / count, b: 0.0)

  result.m = (count * ra.sumXY - ra.sumX * ra.sumY) / d
  result.b = (ra.sumY / count) - (result.m * ra.sumX / count)

proc currentRequestsCosts*(network: LesNetwork,
                           les: ProtocolInfo): seq[ReqCostInfo] =
  # Make sure the message costs are already initialized
  doAssert network.messageStats.len > les.messages[^1].id,
           "Have you called `initFlowControl`"

  for msg in les.messages:
    var (m, b) = network.messageStats[msg.id].calc()
    if m < 0:
      b += m
      m = 0

    if b < 0:
      b = 0

    result.add ReqCostInfo(msgId: msg.id,
                           baseCost: ReqCostInt(b * 2),
                           reqCost: ReqCostInt(m * 2))

proc persistMessageStats*(network: LesNetwork) =
  # XXX: Because of the package_visible_types template magic, Nim complains
  # when we pass the messageStats expression directly to `encodeList`
  let stats = network.messageStats
  network.setSetting(lesStatsKey, rlp.encodeList(lesStatsVer, stats))

proc loadMessageStats*(network: LesNetwork,
                       les: ProtocolInfo): bool =
  block readFromDB:
    var stats = network.getSetting(lesStatsKey)
    if stats.len == 0:
      notice "LES stats not present in the database"
      break readFromDB

    try:
      var statsRlp = rlpFromBytes(stats)
      if not statsRlp.enterList:
        notice "Found a corrupted LES stats record"
        break readFromDB

      let version = statsRlp.read(int)
      if version != lesStatsVer:
        notice "Found an outdated LES stats record"
        break readFromDB

      statsRlp >> network.messageStats
      if network.messageStats.len <= les.messages[^1].id:
        notice "Found an incomplete LES stats record"
        break readFromDB

      return true

    except RlpError as e:
      error "Error while loading LES message stats", err = e.msg

  newSeq(network.messageStats, les.messages[^1].id + 1)
  return false

proc update(s: var FlowControlState, t: LesTime) =
  let dt = max(t - s.lastUpdate, LesTime(0))

  s.bufValue = min(
    s.bufValue + s.minRecharge * dt,
    s.bufLimit)

  s.lastUpdate = t

proc init(s: var FlowControlState,
          bufLimit: BufValueInt, minRecharge: int, t: LesTime) =
  s.bufValue = bufLimit
  s.bufLimit = bufLimit
  s.minRecharge = minRecharge
  s.lastUpdate = t

#func canMakeRequest(s: FlowControlState,
#                    maxCost: ReqCostInt): (LesTime, float64) =
#  ## Returns the required waiting time before sending a request and
#  ## the estimated buffer level afterwards (as a fraction of the limit)
#  const safetyMargin = 50
#
#  var maxCost = min(
#    maxCost + safetyMargin * s.minRecharge,
#    s.bufLimit)
#
#  if s.bufValue >= maxCost:
#    result[1] = float64(s.bufValue - maxCost) / float64(s.bufLimit)
#  else:
#    result[0] = (maxCost - s.bufValue) / s.minRecharge

func canServeRequest(srv: LesNetwork): bool =
  result = srv.reqCount < srv.maxReqCount and
           srv.reqCostSum < srv.maxReqCostSum

proc rechargeReqCost(peer: LesPeer, t: LesTime) =
  let dt = t - peer.lastRechargeTime
  peer.reqCostVal += peer.reqCostGradient * dt / rechargingScale
  peer.lastRechargeTime = t
  if peer.isRecharging and t >= peer.rechargingEndsAt:
    peer.isRecharging = false
    peer.reqCostGradient = 0
    peer.reqCostVal = 0

proc updateRechargingParams(peer: LesPeer, network: LesNetwork) =
  peer.reqCostGradient = 0
  if peer.reqCount > 0:
    peer.reqCostGradient = rechargingScale / network.reqCount

  if peer.isRecharging:
    peer.reqCostGradient = (network.rechargingRate * (peer.rechargingPower /
                                    network.totalRechargingPower).int64).int
    peer.rechargingEndsAt = peer.lastRechargeTime +
                            LesTime(peer.reqCostVal * rechargingScale /
                                         -peer.reqCostGradient        )

proc trackRequests(network: LesNetwork, peer: LesPeer, reqCountChange: int) =
  peer.reqCount += reqCountChange
  network.reqCount += reqCountChange

  doAssert peer.reqCount >= 0 and network.reqCount >= 0

  if peer.reqCount == 0:
    # All requests have been finished. Start recharging.
    peer.isRecharging = true
    network.totalRechargingPower += peer.rechargingPower
  elif peer.reqCount == reqCountChange and peer.isRecharging:
    # `peer.reqCount` must have been 0 for the condition above to hold.
    # This is a transition from recharging to serving state.
    peer.isRecharging = false
    network.totalRechargingPower -= peer.rechargingPower
    peer.startReqCostVal = peer.reqCostVal

  updateRechargingParams peer, network

proc updateFlowControl(network: LesNetwork, t: LesTime) =
  while true:
    var firstTime = t
    for peer in network.peers:
      # TODO: perhaps use a bin heap here
      if peer.isRecharging and peer.rechargingEndsAt < firstTime:
        firstTime = peer.rechargingEndsAt

    let rechargingEndedForSomePeer = firstTime < t

    network.reqCostSum = 0
    for peer in network.peers:
      peer.rechargeReqCost firstTime
      network.reqCostSum += peer.reqCostVal

    if rechargingEndedForSomePeer:
      for peer in network.peers:
        if peer.isRecharging:
          updateRechargingParams peer, network
    else:
      network.lastUpdate = t
      return

proc endPendingRequest*(network: LesNetwork, peer: LesPeer, t: LesTime) =
  if peer.reqCount > 0:
    network.updateFlowControl t
    network.trackRequests peer, -1
    network.updateFlowControl t

proc enlistInFlowControl*(network: LesNetwork,
                          peer: LesPeer,
                          peerRechargingPower = 100) =
  let t = now()

  doAssert peer.isServer or peer.isClient
    # Each Peer must be potential communication partner for us.
    # There will be useless peers on the network, but the logic
    # should make sure to disconnect them earlier in `onPeerConnected`.

  if peer.isServer:
    peer.localFlowState.init network.bufferLimit, network.minRechargingRate, t
    peer.pendingReqs = initTable[int, ReqCostInt]()

  if peer.isClient:
    peer.remoteFlowState.init network.bufferLimit, network.minRechargingRate, t
    peer.lastRechargeTime = t
    peer.rechargingEndsAt = t
    peer.rechargingPower = peerRechargingPower

  network.updateFlowControl t

proc delistFromFlowControl*(network: LesNetwork, peer: LesPeer) =
  let t = now()

  # XXX: perhaps this is not safe with our reqCount logic.
  # The original code may depend on the binarity of the `serving` flag.
  network.endPendingRequest peer, t
  network.updateFlowControl t

proc initFlowControl*(network: LesNetwork, les: ProtocolInfo,
                      maxReqCount, maxReqCostSum, reqCostTarget: int) =
  network.rechargingRate = rechargingScale * (rechargingScale /
                           (100 * rechargingScale / reqCostTarget - rechargingScale))
  network.maxReqCount = maxReqCount
  network.maxReqCostSum = maxReqCostSum

  if not network.loadMessageStats(les):
    warn "Failed to load persisted LES message stats. " &
         "Flow control will be re-initilized."

#proc canMakeRequest(peer: var LesPeer, maxCost: int): (LesTime, float64) =
#  peer.localFlowState.update now()
#  return peer.localFlowState.canMakeRequest(maxCost)

template getRequestCost(peer: LesPeer, localOrRemote: untyped,
                        msgId, costQuantity: int): ReqCostInt =
  let
    baseCost = peer.`localOrRemote ReqCosts`[msgId].baseCost
    reqCost  = peer.`localOrRemote ReqCosts`[msgId].reqCost

  min(baseCost + reqCost * costQuantity,
      peer.`localOrRemote FlowState`.bufLimit)

proc trackOutgoingRequest*(network: LesNetwork, peer: LesPeer,
                           msgId, reqId, costQuantity: int) =
  let maxCost = peer.getRequestCost(local, msgId, costQuantity)

  peer.localFlowState.bufValue -= maxCost
  peer.pendingReqsCost += maxCost
  peer.pendingReqs[reqId] = peer.pendingReqsCost

proc trackIncomingResponse*(peer: LesPeer, reqId: int, bv: BufValueInt) =
  let bv = min(bv, peer.localFlowState.bufLimit)
  if not peer.pendingReqs.hasKey(reqId):
    return

  let costsSumAtSending = peer.pendingReqs.pop(reqId)
  let costsSumChange = peer.pendingReqsCost - costsSumAtSending

  peer.localFlowState.bufValue = if bv > costsSumChange: bv - costsSumChange
                                 else: 0
  peer.localFlowState.lastUpdate = now()

proc acceptRequest*(network: LesNetwork, peer: LesPeer,
                    msgId, costQuantity: int): Future[bool] {.async.} =
  let t = now()
  let reqCost = peer.getRequestCost(remote, msgId, costQuantity)

  peer.remoteFlowState.update t
  network.updateFlowControl t

  while not network.canServeRequest:
    await sleepAsync(chronos.milliseconds(10))

  if peer notin network.peers:
    # The peer was disconnected or the network
    # was shut down while we waited
    return false

  network.trackRequests peer, +1
  network.updateFlowControl network.lastUpdate

  if reqCost > peer.remoteFlowState.bufValue:
    error "LES peer sent request too early",
          recharge = (reqCost - peer.remoteFlowState.bufValue) * rechargingScale /
                                peer.remoteFlowState.minRecharge
    return false

  return true

proc bufValueAfterRequest*(network: LesNetwork, peer: LesPeer,
                           msgId: int, quantity: int): BufValueInt =
  let t = now()
  let costs = peer.remoteReqCosts[msgId]
  var reqCost = costs.baseCost + quantity * costs.reqCost

  peer.remoteFlowState.update t
  peer.remoteFlowState.bufValue -= reqCost

  network.endPendingRequest peer, t

  let curReqCost = peer.reqCostVal
  if curReqCost < peer.remoteFlowState.bufLimit:
    let bv = peer.remoteFlowState.bufLimit - curReqCost
    if bv > peer.remoteFlowState.bufValue:
      peer.remoteFlowState.bufValue = bv

  network.messageStats[msgId].addSample(float64(quantity),
                                        float64(curReqCost - peer.startReqCostVal))

  return peer.remoteFlowState.bufValue

when defined(testing):
  import unittest2, random, ../../rlpx

  proc isMax(s: FlowControlState): bool =
    s.bufValue == s.bufLimit

  p2pProtocol dummyLes(version = 1, rlpxName = "abc"):
    proc a(p: Peer)
    proc b(p: Peer)
    proc c(p: Peer)
    proc d(p: Peer)
    proc e(p: Peer)

  template fequals(lhs, rhs: float64, epsilon = 0.0001): bool =
    abs(lhs-rhs) < epsilon

  proc tests* =
    randomize(3913631)

    suite "les flow control":
      suite "running averages":
        test "consistent costs":
          var s: StatsRunningAverage
          for i in 0..100:
            s.addSample(5.0, 100.0)

          let (cost, base) = s.calc

          check:
            fequals(cost, 100.0)
            fequals(base, 0.0)

        test "randomized averages":
          proc performTest(qBase, qRandom: int, cBase, cRandom: float64) =
            var
              s: StatsRunningAverage
              expectedFinalCost = cBase + cRandom / 2
              error = expectedFinalCost

            for samples in [100, 1000, 10000]:
              for i in 0..samples:
                let q = float64(qBase + rand(10))
                s.addSample(q, q * (cBase + rand(cRandom)))

              let (newCost, newBase) = s.calc
              # With more samples, our error should decrease, getting
              # closer and closer to the average (unless we are already close enough)
              let newError = abs(newCost - expectedFinalCost)
              # This check fails with Nim-1.6:
              # check newError < error
              error = newError

            # After enough samples we should be very close the final result
            check error < (expectedFinalCost * 0.02)

          performTest(1, 10, 5.0, 100.0)
          performTest(1, 4, 200.0, 1000.0)

      suite "buffer value calculations":
        type TestReq = object
          peer: LesPeer
          msgId, quantity: int
          accepted: bool

        setup:
          var lesNetwork = new LesNetwork
          lesNetwork.peers = initHashSet[LesPeer]()
          lesNetwork.initFlowControl(dummyLes.protocolInfo,
                                     reqCostTarget = 300,
                                     maxReqCount = 5,
                                     maxReqCostSum = 1000)

          for i in 0 ..< lesNetwork.messageStats.len:
            lesNetwork.messageStats[i].addSample(1.0, float(i) * 100.0)

          var client = new LesPeer
          client.isClient = true

          var server = new LesPeer
          server.isServer = true

          var clientServer = new LesPeer
          clientServer.isClient = true
          clientServer.isServer = true

          var client2 = new LesPeer
          client2.isClient = true

          var client3 = new LesPeer
          client3.isClient = true

          var bv: BufValueInt

        template enlist(peer: LesPeer) {.dirty.} =
          let reqCosts = currentRequestsCosts(lesNetwork, dummyLes.protocolInfo)
          peer.remoteReqCosts = reqCosts
          peer.localReqCosts = reqCosts
          lesNetwork.peers.incl peer
          lesNetwork.enlistInFlowControl peer

        template startReq(p: LesPeer, msg, q: int): TestReq =
          var req: TestReq
          req.peer = p
          req.msgId = msg
          req.quantity = q
          req.accepted = waitFor lesNetwork.acceptRequest(p, msg, q)
          req

        template endReq(req: TestReq): BufValueInt =
          bufValueAfterRequest(lesNetwork, req.peer, req.msgId, req.quantity)

        test "single peer recharging":
          lesNetwork.bufferLimit = 1000
          lesNetwork.minRechargingRate = 100

          enlist client

          check:
            client.remoteFlowState.isMax
            client.rechargingPower > 0

          advanceTime 100

          let r1 = client.startReq(0, 100)
          check r1.accepted
          check client.isRecharging == false

          advanceTime 50

          let r2 = client.startReq(1, 1)
          check r2.accepted
          check client.isRecharging == false

          advanceTime 25
          bv = endReq r2
          check client.isRecharging == false

          advanceTime 130
          bv = endReq r1
          check client.isRecharging == true

          advanceTime 300
          lesNetwork.updateFlowControl now()

          check:
            client.isRecharging == false
            client.remoteFlowState.isMax

