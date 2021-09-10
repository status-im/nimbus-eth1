# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[algorithm, os, random, sequtils, strformat, strutils, times],
  ../nimbus/utils/tx_pool,
  ./test_txpool/helpers,
  eth/[common, keys],
  stint,
  unittest2

const
  prngSeed = 42
  baseDir = "tests"
  mainnetCapture = "test_txpool" / "mainnet50688.txt.gz"
  goerliCapture = "test_clique" / "goerli51840.txt.gz"
  loadFile = goerliCapture

  # 85% <= #local/#remote <= 1/85%
  # note: by law of big numbers, the ratio will exceed any upper or lower
  #       on a +1/-1 random walk if running long enough (with expectation
  #       value 0)
  localRemoteRatioBandPC = 85

  # 95% <= #remote-deleted/#remote-present <= 1/95%
  deletedItemsRatioBandPC = 95

  # 70% <= #addr-local/#addr-remote <= 1/70%
  # note: this ratio might vary due to timing race conditions
  addrGroupLocalRemotePC = 70

var
  prng = prngSeed.initRand

  # to be set up in runTxLoader()
  okCount: array[bool,int] # entries: [local,remote] entries
  txList: seq[TxItemRef]
  gasPrices: seq[GasInt]
  gasTipCaps: seq[GasInt]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc randOkRatio: int =
  if okCount[false] == 0:
    int.high
  else:
    (okCount[true] * 100 / okCount[false]).int

proc randOk: bool =
  result = prng.rand(1) > 0
  okCount[result].inc


proc collectTxPool(xp: var TxPool; noisy: bool; file: string; stopAfter: int) =
  var
    count = 0
    chainNo = 0
  for chain in file.undumpNextGroup:
    for chainInx in 0 ..< chain[0].len:
      let
        blkNum = chain[0][chainInx].blockNumber
        txs = chain[1][chainInx].transactions
      for n in 0 ..< txs.len:
        count.inc
        let
          local = randOK()
          localInfo = if local: "L" else: "R"
          info = &"{count} #{blkNum}({chainNo}) {n}/{txs.len} {localInfo}"
        noisy.showElapsed(&"insert: local={local} {info}"):
          var tx = txs[n]
          if local:
            doAssert xp.addLocal(tx, info = info).isOK
          else:
            doAssert xp.addRemote(tx, info = info).isOK
        if stopAfter <= count:
          return
    chainNo.inc


proc toTxPool(q: var seq[TxItemRef]; noisy = true): TxPool =
  result.init
  noisy.showElapsed(&"Loading {q.len} transactions"):
    for w in q:
      var tx = w.tx
      if w.local:
        doAssert result.addLocal(tx, w.info).isOK
      else:
        doAssert result.addRemote(tx, w.info).isOK
  doAssert result.count == q.len


proc toTxPool(q: var seq[TxItemRef]; noisy = true;
              timeGap: var Time; nRemoteGapItems: var int;
              remoteItemsPC = 30; delayMSecs = 200): TxPool =
  ## Variant of `toTxPool()` where the loader sleeps some time after
  ## `remoteItemsPC` percent loading remote items.
  doAssert 0 < remoteItemsPC and remoteItemsPC < 100
  result.init
  var
    delayAt = okCount[false] * remoteItemsPC div 100
    middleOfTimeGap = initDuration(milliSeconds = delayMSecs div 2)
    remoteCount = 0
  noisy.showElapsed(&"Loading {q.len} transactions"):
    for w in q:
      var tx = w.tx
      if w.local:
        doAssert result.addLocal(tx, w.info).isOK
      else:
        doAssert result.addRemote(tx, w.info).isOK
      if not w.local and remoteCount < delayAt:
        remoteCount.inc
        if delayAt == remoteCount:
          nRemoteGapItems = remoteCount
          noisy.say &"time gap after {remoteCount} remote transactions"
          timeGap = result.get(w.id).value.timeStamp + middleOfTimeGap
          delayMSecs.sleep
  doAssert result.count == q.len


proc addOrFlushGroupwise(xp: var TxPool;
                         grpLen: int; seen: var seq[Hash256]; n: Hash256;
                         noisy = true) =
  seen.add n
  if seen.len < grpLen:
    return

  # flush group-wise
  let xpLen = xp.count
  noisy.say "*** updateSeen: deleting ", seen.mapIt($it).join(" ")
  for a in seen:
    doAssert xp.delete(a).value.id == a
  doAssert xpLen == seen.len + xp.count
  seen.setLen(0)

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runTxLoader(noisy = true;
                 dir = baseDir; captureFile = loadFile, numTransactions = 0) =
  let
    elapNoisy = noisy
    veryNoisy = false # noisy
    stopAfter = if numTransactions == 0: 900 else: numTransactions
    name = captureFile.splitFile.name.split(".")[0]

  # Reset/initialise
  okCount.reset
  txList.reset
  gasPrices.reset
  gasTipCaps.reset

  suite &"TxPool: Transactions from {name} capture":
    var xp = initTxPool()
    check txList.len == 0

    test &"Collected {stopAfter} transactions":
      elapNoisy.showElapsed("Total collection time"):
        xp.collectTxPool(veryNoisy, dir / captureFile, stopAfter)

      check okCount[true] + okCount[false] == xp.count

      # make sure that PRNG did not go bunkers
      let localRemoteRatio = randOkRatio()
      check localRemoteRatioBandPC < localRemoteRatio
      check localRemoteRatio < (10000 div localRemoteRatioBandPC)

      # Note: expecting enough transactions in the `goerliCapture` file
      check xp.count == stopAfter
      check xp.verify.isOk

      # Load txList[]
      for localOk in [true, false]:
        for w in xp.rangeFifo(localOk):
          txList.add w
      check txList.len == xp.count

    test "Load gas prices and priority fees":

      elapNoisy.showElapsed("Load gas prices"):
        for it in xp.byGasPriceInc:
          gasPrices.add it.itemList.firstKey.value.tx.gasPrice
      check gasPrices.len == xp.byGasPriceLen

      elapNoisy.showElapsed("Load priority fee caps"):
        for it in xp.byGasTipCapInc:
          gasTipCaps.add it.itemList.firstKey.value.tx.maxPriorityFee
      check gasTipCaps.len == xp.byGasTipCapLen


proc runTxBaseTests(noisy = true) =

  let elapNoisy = false

  suite "TxPool: Play with queues and lists against captured transactions":

    var xq = txList.toTxPool(noisy)
    let
      nLocal = xq.localCount
      nRemote = xq.remoteCount

    test &"Swap local/remote ({nLocal}/{nRemote}) queues":
      check nLocal + nRemote == txList.len

      # Start with local queue
      for w in [(true, 0, nLocal), (false, nLocal, txList.len)]:
        let isLocal = w[0]
        for n in w[1] ..< w[2]:
          check txList[n].local == isLocal
          check xq.reassign(txList[n].id, not isLocal)
          check txList[n].info == xq.last(not isLocal).value.info

      check nLocal == xq.remoteCount
      check nRemote == xq.localCount

      # Verify sorting of swapped queue
      var count, n: int

      count = 0
      for (localOK, start) in [(true, nLocal), (false, 0)]:
        var rc = xq.first(localOK)
        n = start
        while rc.isOK and n < txList.len:
          check txList[n].info == rc.value.info
          rc = xq.next(rc.value.id, localOK)
          n.inc
          count.inc
      check count == txList.len
      check n == nLocal

      # And reverse
      count = 0
      for (localOK, top) in [(false, nLocal), (true, txList.len)]:
        var rc = xq.last(localOK)
        n = top
        while rc.isOK and 0 < n:
          n.dec
          check txList[n].info == rc.value.info
          rc = xq.prev(rc.value.id, localOK)
          count.inc
      check count == txList.len
      check n == nLocal

    # ---------------------------------

    block:
      var xq = txList.toTxPool(noisy)
      let veryNoisy = noisy and false

      test &"Walk {xq.byGasPriceLen} gas prices for {txList.len} transactions":
        block:
          var
            txCount = 0
            gpList: seq[GasInt]

          elapNoisy.showElapsed("Increasing gas price walk on transactions"):
            for it in xq.byGasPriceInc:
              let gasPrice = it.itemList.firstKey.value.tx.gasPrice
              var infoList: seq[string]
              for w in it.itemList.nextKeys: # prevKeys() also works
                infoList.add w.info
              gpList.add gasPrice
              txCount += it.itemList.len
              veryNoisy.say &"gasPrice={gasPrice} for {infoList.len} entries:"
              let indent = " ".repeat(6)
              veryNoisy.say indent, infoList.join(&"\n{indent}")

          check txCount == xq.count
          check gpList.len == xq.byGasPriceLen
          check gasPrices == gpList

        block:
          var
            gpCount = 0
            txCount = 0
            gpList: seq[GasInt]

          elapNoisy.showElapsed("Decreasing gas price walk on transactions"):
            for it in xq.byGasPriceDec:
              let gasPrice = it.itemList.firstKey.value.tx.gasPrice
              var infoList: seq[string]
              for w in it.itemList.prevKeys: # nextKeys() also works
                infoList.add w.info
              gpList.add gasPrice
              txCount += it.itemList.len
              veryNoisy.say &"gasPrice={gasPrice} for {infoList.len} entries:"
              let indent = " ".repeat(6)
              veryNoisy.say indent, infoList.join(&"\n{indent}")

          check txCount == xq.count
          check gpList.len == xq.byGasPriceLen
          check gasPrices == gpList.reversed

      test "Walk transaction ID queue fwd/rev":
        block:
          var top = 0
          for localOk in [true, false]:
            for w in xq.rangeFifo(localOk):
              check txList[top].id == w.id
              top.inc
          check top == txList.len
        block:
          var top = txList.len
          for localOk in [false, true]:
            for w in xq.rangeLifo(localOk):
              top.dec
              check txList[top].id == w.id
          check top == 0

    # ---------------------------------

    block:
      const groupLen = 13
      let veryNoisy = noisy and false

      test &"Load/forward walk ID queue, " &
          &"deleting groups of at most {groupLen}":
        var
          xq = txList.toTxPool(noisy)
          seen: seq[Hash256]
        check xq.verify.isOK
        elapNoisy.showElapsed("Forward delete-walk ID queue"):
          for localOk in [true, false]:
            for w in xq.rangeFifo(localOk):
              xq.addOrFlushGroupwise(groupLen, seen, w.id, veryNoisy)
              check xq.verify.isOK
        check seen.len == xq.count
        check seen.len < groupLen

      test &"Load/reverse walk ID queue, " &
          &"deleting in groups of at most {groupLen}":
        var
          xq = txList.toTxPool(noisy)
          seen: seq[Hash256]
        check xq.verify.isOK
        elapNoisy.showElapsed("Revese delete-walk ID queue"):
          for localOk in [false, true]:
            for w in xq.rangeLifo(localOk):
              xq.addOrFlushGroupwise(groupLen, seen, w.id, veryNoisy)
            check xq.verify.isOK
        check seen.len == xq.count
        check seen.len < groupLen

    # ---------------------------------

    block:
      var
        xq = txList.toTxPool(noisy)
        count = 0
      let
        delLe = gasPrices[0] + ((gasPrices[^1] - gasPrices[0]) div 3)
        delMax = block:
          var it = xq.byGasPriceLe(delLe).value
          it.itemList.firstKey.value.tx.gasPrice

      test &"Load/delete with gas price less equal {delMax.toKMG}, " &
          &"out of price range {gasPrices[0].toKMG}..{gasPrices[^1].toKMG}":
        elapNoisy.showElapsed(&"Deleting gas prices less equal {delMax.toKMG}"):
          for it in xq.byGasPriceDec(fromLe = delMax):
            for item in it.itemList.nextKeys:
              count.inc
              check xq.delete(item).isOK
              check xq.verify.isOK
        check 0 < count
        check 0 < xq.count
        check count + xq.count == txList.len

    block:
      var
        xq = txList.toTxPool(noisy)
        count = 0
      let
        delGe = gasPrices[^1] - ((gasPrices[^1] - gasPrices[0]) div 3)
        delMin = block:
          var it = xq.byGasPriceGe(delGe).value
          it.itemList.firstKey.value.tx.gasPrice

      test &"Load/delete with gas price greater equal {delMin.toKMG}, " &
          &"out of price range {gasPrices[0].toKMG}..{gasPrices[^1].toKMG}":
        elapNoisy.showElapsed(
            &"Deleting gas prices greater than {delMin.toKMG}"):
          for it in xq.byGasPriceInc(fromGe = delMin):
            for item in it.itemList.nextKeys:
              count.inc
              check xq.delete(item).isOK
              check xq.verify.isOK
        check 0 < count
        check 0 < xq.count
        check count + xq.count == txList.len


proc runTxPoolTests(noisy = true) =

  suite "TxPool: Play with pool functions and primitives":

    block:
      var
        gap: Time
        nItems: int
        xq = txList.toTxPool(noisy, gap, nItems,
                             remoteItemsPC = 35, # arbitrary
                             delayMSecs = 100)   # large enough to be found

      test &"Delete about {nItems} expired non-local transactions "&
          &"out of {xq.remoteCount}":

        check 0 < nItems
        xq.lifeTime = getTime() - gap

        check xq.job(TxJobData(kind: txJobsInactiveJobsEviction)).isJobOk
        check xq.commit == 1
        check xq.localCount == okCount[true]

        # make sure that deletion was sort of expected
        let
          deletedItems = txList.len - xq.count
          deleteExpextRatio = (deletedItems * 100 / nItems).int
        check deletedItemsRatioBandPC < deleteExpextRatio
        check deleteExpextRatio < (10000 div deletedItemsRatioBandPC)

    # ---------------------------------

    block:
      var
        xq = txList.toTxPool(noisy)
        maxAddr: EthAddress
        nAddrItems = 0
        nAddrRemotes = 0
        nLocalAddr = toSeq(xq.locals).len

      test "About half of transactions in largest address group are remotes":

        # find address with max number of transactions
        for it in xq.bySenderGroups:
          if nAddrItems < it.itemListLen:
            var rc = it.itemList(local = false).firstKey
            if rc.isErr:
              rc = it.itemList(local = true).firstKey
            maxAddr = rc.value.sender
            nAddrItems = it.itemListLen
        check 0 < nAddrItems

        # count the number of remotes
        nAddrRemotes = xq.bySenderEq(maxAddr).value.itemListLen(local = false)

        # make sure that local/remote ratio makes sense
        let localRemoteRatio =
           (((nAddrItems - nAddrRemotes) * 100) / nAddrRemotes).int
        check addrGroupLocalRemotePC < localRemoteRatio
        check localRemoteRatio < (10000 div addrGroupLocalRemotePC)

      test &"Reassign {nAddrRemotes} remotes to locals in largest "&
        &"address group with {nAddrItems} entries":

        let
          nLocals = xq.localCount
          nRemotes = xq.remoteCount
          nMoved = xq.remoteToLocals(maxAddr)

        check xq.verify.isOK
        check xq.bySenderEq(maxAddr).value.itemListLen(local = false) == 0
        check nMoved == nAddrRemotes
        check nLocals + nMoved == xq.localCount
        check nRemotes - nMoved == xq.remoteCount
        check nLocalAddr == toSeq(xq.locals).len

      test &"Delete locals from largest address group so it becomes empty":

        let list = xq.bySenderEq(maxAddr).value
        for item in list.itemList(local = true).nextKeys:
          doAssert xq.delete(item.id).isOK

        check nLocalAddr == toSeq(xq.locals).len + 1
        check xq.verify.isOK

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc txPoolMain*(noisy = defined(debug)) =
  noisy.runTxLoader
  noisy.runTxBaseTests
  noisy.runTxPoolTests

when isMainModule:
  let
    captFile1 = "goerli504192.txt.gz"
    captFile2 = "mainnet843841.txt.gz"

  let noisy = defined(debug)

  noisy.runTxLoader(
    dir = "/status", captureFile = captFile2, numTransactions = 1500)
  #noisy.runTxBaseTests
  noisy.runTxPoolTests

  #noisy.runTxLoader(dir = ".")
  #noisy.runTxPoolTests

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
