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

  # 75% <= #local/#remote <= 1/75%
  # note: by law of big numbers, the ratio will exceed any upper or lower
  #       on a +1/-1 random walk if running long enough (with expectation
  #       value 0)
  localRemoteRatioBandPC = 75

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
  effGasTips: seq[GasInt]
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


proc lstShow(xp: var TxPool; pfx = "*** "): string =
  pfx & "txList=" & txList.mapIt(it.pp).join(" ") & "\n" &
    pfx & "fifo=" & toSeq(xp.rangeFifo(true,false)).mapIt(it.pp).join(" ")


proc collectTxPool(xp: var TxPool;
                   noisy: bool; file: string; stopAfter: int) =
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


proc toTxPool(q: var seq[TxItemRef]; baseFee: GasInt; noisy = true): TxPool =
  result.init(baseFee)
  noisy.showElapsed(&"Loading {q.len} transactions"):
    for w in q:
      var tx = w.tx
      if w.local:
        doAssert result.addLocal(tx, w.info).isOK
      else:
        doAssert result.addRemote(tx, w.info).isOK
  doAssert result.count == q.len


proc toTxPool(q: var seq[TxItemRef]; baseFee: GasInt; noisy = true;
              timeGap: var Time; nRemoteGapItems: var int;
              remoteItemsPC = 30; delayMSecs = 200): TxPool =
  ## Variant of `toTxPool()` where the loader sleeps some time after
  ## `remoteItemsPC` percent loading remote items.
  doAssert 0 < remoteItemsPC and remoteItemsPC < 100
  result.init(baseFee)
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
          timeGap = result.get(w.itemID).value.timeStamp + middleOfTimeGap
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
    doAssert xp.txDB.delete(a).value.itemID == a
  doAssert xpLen == seen.len + xp.count
  seen.setLen(0)

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runTxLoader(noisy = true; baseFee: GasInt;
                 dir = baseDir; captureFile = loadFile, numTransactions = 0) =
  let
    elapNoisy = noisy
    veryNoisy = false # noisy
    stopAfter = if numTransactions == 0: 900 else: numTransactions
    name = captureFile.splitFile.name.split(".")[0]
    baseInfo = if baseFee != TxNoBaseFee: &" with baseFee={baseFee}" else: ""

  # Reset/initialise
  okCount.reset
  txList.reset
  effGasTips.reset
  gasTipCaps.reset

  suite &"TxPool: Transactions from {name} capture{baseInfo}":
    var xp = init(type TxPool, baseFee)
    check txList.len == 0
    check xp.txDB.verify.isOK

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
      for w in xp.rangeFifo(true, false):
        txList.add w
      check txList.len == xp.count

    test "Load gas prices and priority fees":

      elapNoisy.showElapsed("Load gas prices"):
        for gasData in xp.txDB.byPriceIncNonce:
          effGasTips.add gasData.effectiveGasTip
      check effGasTips.len == xp.txDB.byPriceLen

      elapNoisy.showElapsed("Load priority fee caps"):
        for tipData in xp.txDB.byTipCapInc:
          gasTipCaps.add tipData.gasTipCap
      check gasTipCaps.len == xp.txDB.byTipCapLen


proc runTxBaseTests(noisy = true; baseFee: GasInt) =

  let
    elapNoisy = false
    baseInfo = if baseFee != TxNoBaseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Play with queues and lists{baseInfo}":

    var xq = txList.toTxPool(baseFee, noisy)
    let
      nLocal = xq.localCount
      nRemote = xq.remoteCount
      txList0local = txList[0].local

    test &"Swap local/remote ({nLocal}/{nRemote}) queues":
      check nLocal + nRemote == txList.len

      # Start with local queue
      for w in [(true, 0, nLocal), (false, nLocal, txList.len)]:
        let isLocal = w[0]
        for n in w[1] ..< w[2]:
          check txList[n].local == isLocal
          check xq.txDB.reassign(txList[n], not isLocal)
          check txList[n].info == xq.txDB.last(not isLocal).value.info

      check nLocal == xq.remoteCount
      check nRemote == xq.localCount

      # maks sure the list item was left unchanged
      check txList0local == txList[0].local

      # Verify sorting of swapped queue
      var count, n: int

      count = 0
      for (localOK, start) in [(true, nLocal), (false, 0)]:
        var rc = xq.txDB.first(localOK)
        n = start
        while rc.isOK and n < txList.len:
          check txList[n].info == rc.value.info
          rc = xq.txDB.next(rc.value.itemID, localOK)
          n.inc
          count.inc
      check count == txList.len
      check n == nLocal

      # And reverse
      count = 0
      for (localOK, top) in [(false, nLocal), (true, txList.len)]:
        var rc = xq.txDB.last(localOK)
        n = top
        while rc.isOK and 0 < n:
          n.dec
          check txList[n].info == rc.value.info
          rc = xq.txDB.prev(rc.value.itemID, localOK)
          count.inc
      check count == txList.len
      check n == nLocal

    # ---------------------------------

    block:
      var xq = txList.toTxPool(baseFee, noisy)
      let
        veryNoisy = noisy # and false
        indent = " ".repeat(6)

      test &"Walk {xq.txDB.byPriceLen} gas prices "&
          &"for {txList.len} transactions":
        block:
          var
            txCount = 0
            gpList: seq[GasInt]

          elapNoisy.showElapsed("Increasing gas price transactions walk"):
            for gasData in xq.txDB.byPriceIncNonce:
              var
                infoList: seq[string]
                gasTxCount = 0
              for nonceData in gasData.byNonceInc:
                for item in nonceData.itemList.nextKeys:
                  infoList.add item.info
                gasTxCount += nonceData.nItems

              check gasTxCount == gasData.nItems
              txCount += gasTxCount

              let gasTip = gasData.effectiveGasTip
              gpList.add gasTip
              veryNoisy.say &"gasTip={gasTip} for {infoList.len} entries:"
              veryNoisy.say indent, infoList.join(&"\n{indent}")

          check txCount == xq.count
          check gpList.len == xq.txDB.byPriceLen
          check effGasTips.len == gpList.len
          check effGasTips == gpList

        block:
          var
            txCount = 0
            gpList: seq[GasInt]

          elapNoisy.showElapsed("Decreasing gas price transactions walk"):
            for gasData in xq.txDB.byPriceDecNonce:
              var
                infoList: seq[string]
                gasTxCount = 0
              for nonceData in gasData.byNonceDec:
                for it in nonceData.itemList.prevKeys: # nextKeys() also works
                  infoList.add it.info
                gasTxCount += nonceData.nItems

              check gasTxCount == gasData.nItems
              txCount += gasTxCount

              let gasTip = gasData.effectiveGasTip
              gpList.add gasTip
              veryNoisy.say &"gasPrice={gasTip} for {infoList.len} entries:"
              veryNoisy.say indent, infoList.join(&"\n{indent}")

          check txCount == xq.count
          check gpList.len == xq.txDB.byPriceLen
          check effGasTips.len == gpList.len
          check effGasTips == gpList.reversed

      test "Walk transaction ID queue fwd/rev":
        block:
          var top = 0
          for w in xq.rangeFifo(true, false):
            check txList[top].info.split[0] == w.info.split[0]
            # check txList[top].itemID == w.itemID
            top.inc
          check top == txList.len
        block:
          var top = txList.len
          for w in xq.rangeLifo(false, true):
            top.dec
            check txList[top].itemID == w.itemID
          check top == 0

    # ---------------------------------

    block:
      const groupLen = 13
      let veryNoisy = noisy and false

      test &"Load/forward walk ID queue, " &
          &"deleting groups of at most {groupLen}":
        var
          xq = txList.toTxPool(baseFee, noisy)
          seen: seq[Hash256]
        check xq.txDB.verify.isOK
        elapNoisy.showElapsed("Forward delete-walk ID queue"):
          for localOk in [true, false]:
            for w in xq.rangeFifo(localOk):
              xq.addOrFlushGroupwise(groupLen, seen, w.itemID, veryNoisy)
              check xq.txDB.verify.isOK
        check seen.len == xq.count
        check seen.len < groupLen

      test &"Load/reverse walk ID queue, " &
          &"deleting in groups of at most {groupLen}":
        var
          xq = txList.toTxPool(baseFee, noisy)
          seen: seq[Hash256]
        check xq.txDB.verify.isOK
        elapNoisy.showElapsed("Revese delete-walk ID queue"):
          for localOk in [false, true]:
            for w in xq.rangeLifo(localOk):
              xq.addOrFlushGroupwise(groupLen, seen, w.itemID, veryNoisy)
            check xq.txDB.verify.isOK
        check seen.len == xq.count
        check seen.len < groupLen

    # ---------------------------------

    block:
      var
        xq = txList.toTxPool(baseFee, noisy)
        count = 0
      let
        delLe = effGasTips[0] + ((effGasTips[^1] - effGasTips[0]) div 3)
        delMax = xq.txDB.byPriceLe(delLe).value.effectiveGasTip

      test &"Load/delete with gas price less equal {delMax.toKMG}, " &
          &"out of price range {effGasTips[0].toKMG}..{effGasTips[^1].toKMG}":
        elapNoisy.showElapsed(&"Deleting gas tips less equal {delMax.toKMG}"):
          for nonceData in xq.txDB.byPriceDecItem(maxPrice = delMax):
            for item in nonceData.itemList.nextKeys:
              count.inc
              check xq.txDB.delete(item)
              check xq.txDB.verify.isOK
        check 0 < count
        check 0 < xq.count
        check count + xq.count == txList.len

    block:
      var
        xq = txList.toTxPool(baseFee, noisy)
        count = 0
      let
        delGe = effGasTips[^1] - ((effGasTips[^1] - effGasTips[0]) div 3)
        delMin = xq.txDB.byPriceGe(delGe).value.effectiveGasTip

      test &"Load/delete with gas price greater equal {delMin.toKMG}, " &
          &"out of price range {effGasTips[0].toKMG}..{effGasTips[^1].toKMG}":
        elapNoisy.showElapsed(
            &"Deleting gas tips greater than {delMin.toKMG}"):
          for nonceData in xq.txDB.byPriceIncItem(minPrice = delMin):
            for item in nonceData.itemList.nextKeys:
              count.inc
              check xq.txDB.delete(item)
              check xq.txDB.verify.isOK
        check 0 < count
        check 0 < xq.count
        check count + xq.count == txList.len

    block:
      let
        newBaseFee = if baseFee == TxNoBaseFee: 42.GasInt else: baseFee + 7

      test &"Adjust baseFee to {newBaseFee} and back":
        var
          xq = txList.toTxPool(baseFee, noisy)
          baseNonces: seq[AccountNonce] # second level sequence

        # register sequence of nonces
        for gasData in xq.txDB.byPriceIncNonce:
          for nonceData in gasData.byNonceInc:
            baseNonces.add nonceData.nonce

        xq.baseFee = newBaseFee
        block:
          var
            seen: seq[Hash256]
            tips: seq[GasInt]
          for gasData in xq.txDB.byPriceIncNonce:
            tips.add gasData.effectiveGasTip
            for nonceData in gasData.byNonceInc:
              for item in nonceData.itemList.nextKeys:
                seen.add item.itemID
          check txList.len == xq.txDB.nItems
          check txList.len == seen.len
          check tips != effGasTips              # values should have changed
          check seen != txList.mapIt(it.itemID) # order should have changed

        # change back
        xq.baseFee = baseFee
        block:
          var
            seen: seq[Hash256]
            tips: seq[GasInt]
            nces: seq[AccountNonce]
          for gasData in xq.txDB.byPriceIncNonce:
            tips.add gasData.effectiveGasTip
            for nonceData in gasData.byNonceInc:
              nces.add nonceData.nonce
              for item in nonceData.itemList.nextKeys:
                seen.add item.itemID
          check txList.len == xq.txDB.nItems
          check txList.len == seen.len
          check tips == effGasTips              # values restored
          check nces == baseNonces              # values restored
          # note: txList[] will be equivalent to seen[] but not necessary
          #       the same


proc runTxPoolTests(noisy = true; baseFee: GasInt) =
  let
    baseInfo = if baseFee != TxNoBaseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Play with pool functions and primitives{baseInfo}":

    block:
      var
        gap: Time
        nItems: int
        xq = txList.toTxPool(baseFee, noisy, gap, nItems,
                             remoteItemsPC = 35, # arbitrary
                             delayMSecs = 100)   # large enough to be found

      test &"Delete about {nItems} expired non-local transactions "&
          &"out of {xq.remoteCount}":

        check 0 < nItems
        xq.lifeTime = getTime() - gap

        check xq.job(TxJobData(kind: txJobsInactiveJobsEviction)).isJobOk
        check xq.commit == 1
        check xq.localCount == okCount[true]
        check xq.verify.isOK # not: xq.txDB.verify

        # make sure that deletion was sort of expected
        let
          deletedItems = txList.len - xq.count
          deleteExpextRatio = (deletedItems * 100 / nItems).int
        check deletedItemsRatioBandPC < deleteExpextRatio
        check deleteExpextRatio < (10000 div deletedItemsRatioBandPC)

    # ---------------------------------

    block:
      var
        xq = txList.toTxPool(baseFee, noisy)
        maxAddr: EthAddress
        nAddrItems = 0
        nAddrRemoteItems = 0
        nAddrLocalItems = 0
      let
        nLocalAddrs = toSeq(xq.locals).len
        nRemoteAddrs = toSeq(xq.txDB.bySenderNonce(local = false)).len

      test "About half of transactions in largest address group are remotes":

        # find address with max number of transactions
        for schedData in xq.txDB.bySenderSched:
          if nAddrItems < schedData.nItems:
            maxAddr = schedData.sender
            nAddrItems = schedData.nItems
        check 0 < nAddrItems

        # count the number of locals and remotes for this address
        nAddrRemoteItems = xq.txDB.bySenderEq(
                                  maxAddr, local = false).value.nItems
        nAddrLocalItems = nAddrItems - nAddrRemoteItems

        # make sure that local/remote ratio makes sense
        let localRemoteRatio =
           (((nAddrItems - nAddrRemoteItems) * 100) / nAddrRemoteItems).int
        check addrGroupLocalRemotePC < localRemoteRatio
        check localRemoteRatio < (10000 div addrGroupLocalRemotePC)

      test &"Reassign {nAddrRemoteItems} remotes to {nAddrLocalItems} locals "&
          &"in largest address group with {nAddrItems} items":
        let
          nLocals = xq.localCount
          nRemotes = xq.remoteCount
          nMoved = xq.remoteToLocals(maxAddr)

        check xq.txDB.verify.isOK
        check xq.txDB.bySenderEq(maxAddr, local = false).isErr
        check nMoved == nAddrRemoteItems
        check nLocals + nMoved == xq.localCount
        check nRemotes - nMoved == xq.remoteCount

        check nRemoteAddrs ==
                1 + toSeq(xq.txDB.bySenderNonce(local = false)).len

        if 0 < nAddrLocalItems:
          check nLocalAddrs == toSeq(xq.locals).len
        else:
          check nLocalAddrs == 1 + toSeq(xq.locals).len

      test &"Delete locals from largest address group so it becomes empty":

        let addrLocals = xq.txDB.bySenderEq(maxAddr, local = true).value
        for nonceData in addrLocals.byNonceItem:
          for item in nonceData.itemList.nextKeys:
            doAssert xq.txDB.delete(item.itemID).isOK

        check nLocalAddrs == 1 + toSeq(xq.locals).len
        check xq.txDB.verify.isOK

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc txPoolMain*(noisy = defined(debug)) =
  let baseFee = 42.GasInt
  noisy.runTxLoader(baseFee)
  noisy.runTxBaseTests(baseFee)
  noisy.runTxPoolTests(baseFee)

when isMainModule:
  let
    baseFee = 42.GasInt #  TxNoBaseFee
    captFile1 = "goerli504192.txt.gz"
    captFile2 = "mainnet843841.txt.gz"

  let noisy = defined(debug)

  noisy.runTxLoader(
    baseFee,
    dir = "/status", captureFile = captFile2, numTransactions = 1500)
  noisy.runTxBaseTests(baseFee)
  noisy.runTxPoolTests(baseFee)

  noisy.runTxLoader(baseFee, dir = ".")
  #noisy.runTxPoolTests(baseFee)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
