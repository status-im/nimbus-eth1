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
  ../nimbus/chain_config,
  ../nimbus/config,
  ../nimbus/db/db_chain,
  ../nimbus/utils/[slst, tx_pool],
  ../nimbus/utils/tx_pool/[tx_item, tx_perjobapi],
  ./test_txpool/[helpers, setup],
  chronos,
  eth/[common, keys, p2p],
  stint,
  unittest2

type
  CaptureSpecs = tuple
    network: NetworkID
    dir, file: string
    numBlocks, numTxs: int

const
  prngSeed = 42

  goerliCapture: CaptureSpecs = (
    network: GoerliNet,
    dir: "tests",
    file: "replay" / "goerli68161.txt.gz",
    numBlocks: 20000,
    numTxs: 900)

  loadSpecs = goerliCapture

  # 75% <= #local/#remote <= 1/75%
  # note: by law of big numbers, the ratio will exceed any upper or lower
  #       on a +1/-1 random walk if running long enough (with expectation
  #       value 0)
  randInitRatioBandPC = 75

  # 95% <= #remote-deleted/#remote-present <= 1/95%
  deletedItemsRatioBandPC = 95

  # 70% <= #addr-local/#addr-remote <= 1/70%
  # note: this ratio might vary due to timing race conditions
  addrGroupLocalRemotePC = 70

  # test block chain
  networkId = GoerliNet # MainNet

var
  minGasPrice = GasPrice.high
  maxGasPrice = GasPrice.low

  prng = prngSeed.initRand

  # to be set up in runTxLoader()
  okCount: array[bool,int]             # entries: [local,remote] entries
  statCount: array[TxItemStatus,int] # ditto

  txList: seq[TxItemRef]
  effGasTips: seq[GasPriceEx]
  gasTipCaps: seq[GasPrice]

  # running block chain
  bcDB: BaseChainDB

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc randOkRatio: int =
  if okCount[false] == 0:
    int.high
  else:
    (okCount[true] * 100 / okCount[false]).int

proc randStatusRatios: seq[int] =
  for n in 1 .. statCount.len:
    let
      inx = (n mod statCount.len).TxItemStatus
      prv = (n - 1).TxItemStatus
    if statCount[inx] == 0:
      result.add int.high
    else:
      result.add (statCount[prv] * 100 / statCount[inx]).int

proc randOk: bool =
  result = prng.rand(1) > 0
  okCount[result].inc

proc randStatus: TxItemStatus =
  result = prng.rand(TxItemStatus.high.ord).TxItemStatus
  statCount[result].inc

proc toRemote(item: TxItemRef): TxItemRef =
  result = item
  item.local = false

template wrapException(info: string; action: untyped) =
  try:
    action
  except CatchableError:
    raiseAssert info & " has problems: " & getCurrentExceptionMsg()

proc addOrFlushGroupwise(xp: TxPoolRef;
                         grpLen: int; seen: var seq[TxItemRef]; w: TxItemRef;
                         noisy = true): bool =
  # to be run as call back inside `itemsApply()`
  wrapException("addOrFlushGroupwise()"):
    seen.add w
    if grpLen <= seen.len:
      # clear waste basket
      discard xp.txDB.flushRejects

      # flush group-wise
      let xpLen = xp.count.total
      noisy.say "*** updateSeen: deleting ", seen.mapIt($it.itemID).join(" ")
      for item in seen:
        doAssert xp.txDB.dispose(item,txInfoErrUnspecified)
      doAssert xpLen == seen.len + xp.count.total
      doAssert seen.len == xp.count.disposed
      seen.setLen(0)

      # clear waste basket
      discard xp.txDB.flushRejects

    return true

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runTxLoader(noisy = true; baseFee = 0.GasPrice; capture = loadSpecs) =
  let
    elapNoisy = noisy
    veryNoisy = false # noisy
    fileInfo = capture.file.splitFile.name.split(".")[0]
    suiteInfo = if 0 < baseFee: &" with baseFee={baseFee}" else: ""
    file = capture.dir /  capture.file

  # Reset/initialise
  okCount.reset
  statCount.reset
  txList.reset
  effGasTips.reset
  gasTipCaps.reset
  bcDB = capture.network.blockChainForTesting

  suite &"TxPool: Transactions from {fileInfo} capture{suiteInfo}":
    var xp: TxPoolRef

    test &"Import {capture.numBlocks.toKMG} blocks "&
        &"and collect {capture.numTxs} txs":

      elapNoisy.showElapsed("Total collection time"):
        xp = bcDB.toTxPool(file = file,
                           getLocal = randOk,
                           getStatus = randStatus,
                           loadBlocks = capture.numBlocks,
                           loadTxs = capture.numTxs,
                           baseFee = baseFee,
                           noisy = veryNoisy)

      # Set txs to pseudo random status
      xp.setItemStatusFromInfo

      check txList.len == 0
      check xp.txDB.verify.isOK
      check xp.count.disposed == 0

      noisy.say "***",
         "Latest items:",
         " <", xp.txDB.byItemID.eq(local = true).last.value.data.info, ">",
         " <", xp.txDB.byItemID.eq(local = false).last.value.data.info, ">"

      # make sure that the block chain was initialised
      check capture.numBlocks.u256 <= bcDB.getCanonicalHead.blockNumber

      check xp.count.total == foldl(okCount.toSeq, a+b)   # add okCount[] values
      check xp.count.total == foldl(statCount.toSeq, a+b) # ditto statCount[]

      # make sure that PRNG did not go bonkers
      let localRemoteRatio = randOkRatio()
      check randInitRatioBandPC < localRemoteRatio
      check localRemoteRatio < (10000 div randInitRatioBandPC)

      for statusRatio in randStatusRatios():
        check randInitRatioBandPC < statusRatio
        check statusRatio < (10000 div randInitRatioBandPC)

      # Note: expecting enough transactions in the `goerliCapture` file
      check xp.count.total == capture.numTxs
      check xp.verify.isOk

      # Load txList[]
      txList = xp.toItems
      check txList.len == xp.count.total

    test "Load gas prices and priority fees":

      elapNoisy.showElapsed("Load gas prices"):
        for nonceList in xp.txDB.byGasTip.incNonceList:
          effGasTips.add nonceList.ge(AccountNonce.low).first.value.effGasTip

      check effGasTips.len == xp.txDB.byGasTip.len

      elapNoisy.showElapsed("Load priority fee caps"):
        for itemList in xp.txDB.byTipCap.incItemList:
          gasTipCaps.add itemList.first.value.tx.gasTipCap

          # just handy to calc min/max gas prices here
          for item in itemList.walkItems:
            if item.tx.gasPrice.GasPriceEx < minGasPrice and 0 < item.tx.gasPrice:
              minGasPrice = item.tx.gasPrice.GasPrice
            if maxGasPrice < item.tx.gasPrice.GasPrice:
              maxGasPrice = item.tx.gasPrice.GasPrice

      check minGasPrice <= maxGasPrice
      check gasTipCaps.len == xp.txDB.byTipCap.len

    test &"Concurrent job processing, test for race conditions":
      var log = ""

      proc delayJob(xp: TxPoolRef; tmo: int) {.async.} =
        let n = xp.nJobsWaiting
        xp.job(TxJobDataRef(kind: txJobNone))
        xp.job(TxJobDataRef(kind: txJobNone))
        xp.job(TxJobDataRef(kind: txJobNone))
        log &= " wait-" & $tmo & "-" & $(xp.nJobsWaiting - n)
        await chronos.milliseconds(tmo).sleepAsync
        await xp.jobCommit
        log &= " done-" & $tmo

      # run async jobs, completion should be sorted by timeout argument
      #
      # this proves, that the `jobCommit()` directive properly runs the
      # latest batch of jobs -- maybe waiting for some other job to finish
      proc runJobs(xp: TxPoolRef) {.async.} =
        let
          p1 = xp.delayJob(900)
          p2 = xp.delayJob(1)
          p3 = xp.delayJob(700)
        await p3
        await p2
        await p1

      waitFor xp.runJobs
      check xp.nJobsWaiting == 0
      check log == " wait-900-3 wait-1-3 wait-700-3 done-1 done-700 done-900"
      check xp.verify.isOK


proc runTxBaseTests(noisy = true; baseFee = 0.GasPrice) =

  let
    elapNoisy = false
    baseInfo = if 0 < baseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Play with queues and lists{baseInfo}":

    var xq = bcDB.toTxPool(txList, baseFee, noisy = noisy)

    # Set txs to pseudo random status
    xq.setItemStatusFromInfo

    let
      nLocal = xq.count.local
      nRemote = xq.count.remote
      txList0local = txList[0].local

    test &"Swap local/remote ({nLocal}/{nRemote}) queues":
      check nLocal + nRemote == txList.len

      # Start with local queue
      for w in [(true, 0, nLocal), (false, nLocal, txList.len)]:
        let local = w[0]
        for n in w[1] ..< w[2]:
          check txList[n].local == local
          check xq.txDB.reassign(txList[n], not local)
          check txList[n].info == xq.txDB.byItemID
                                         .eq(not local).last.value.data.info
          check xq.txDB.verify.isOK

      check nLocal == xq.count.remote
      check nRemote == xq.count.local

      # maks sure the list item was left unchanged
      check txList0local == txList[0].local

      # Verify sorting of swapped queue
      var count, n: int

      count = 0
      for (local, start) in [(true, nLocal), (false, 0)]:
        var rc = xq.txDB.byItemID.eq(local).first
        n = start
        while rc.isOK and n < txList.len:
          check txList[n].info == rc.value.data.info
          rc = xq.txDB.byItemID.eq(local).next(rc.value.data.itemID)
          n.inc
          count.inc
      check count == txList.len
      check n == nLocal

      # And reverse
      count = 0
      for (local, top) in [(false, nLocal), (true, txList.len)]:
        var rc = xq.txDB.byItemID.eq(local).last
        n = top
        while rc.isOK and 0 < n:
          n.dec
          check txList[n].info == rc.value.data.info
          rc = xq.txDB.byItemID.eq(local).prev(rc.value.data.itemID)
          count.inc
      check count == txList.len
      check n == nLocal

    # ---------------------------------

    block:
      var xq = bcDB.toTxPool(txList, baseFee, noisy = noisy)

      # Set txs to pseudo random status
      xq.setItemStatusFromInfo

      let
        veryNoisy = noisy # and false
        indent = " ".repeat(6)

      test &"Walk {xq.txDB.byGasTip.len} gas prices "&
          &"for {txList.len} transactions":
        block:
          var
            txCount = 0
            gpList: seq[GasPriceEx]

          elapNoisy.showElapsed("Increasing gas price transactions walk"):
            for nonceList in xq.txDB.byGasTip.incNonceList:
              var
                infoList: seq[string]
                gasTxCount = 0
              for itemList in nonceList.incItemList:
                for item in itemList.walkItems:
                  infoList.add item.info
                gasTxCount += itemList.nItems

              check gasTxCount == nonceList.nItems
              txCount += gasTxCount

              let gasTip = nonceList.ge(AccountNonce.low).first.value.effGasTip
              gpList.add gasTip
              veryNoisy.say &"gasTip={gasTip} for {infoList.len} entries:"
              veryNoisy.say indent, infoList.join(&"\n{indent}")

          check txCount == xq.count.total
          check gpList.len == xq.txDB.byGasTip.len
          check effGasTips.len == gpList.len
          check effGasTips == gpList

        block:
          var
            txCount = 0
            gpList: seq[GasPriceEx]

          elapNoisy.showElapsed("Decreasing gas price transactions walk"):
            for nonceList in xq.txDB.byGasTip.decNonceList:
              var
                infoList: seq[string]
                gasTxCount = 0
              for itemList in nonceList.decItemList:
                for item in itemList.walkItems:
                  infoList.add item.info
                gasTxCount += itemList.nItems

              check gasTxCount == nonceList.nItems
              txCount += gasTxCount

              let gasTip = nonceList.ge(AccountNonce.low).first.value.effGasTip
              gpList.add gasTip
              veryNoisy.say &"gasPrice={gasTip} for {infoList.len} entries:"
              veryNoisy.say indent, infoList.join(&"\n{indent}")

          check txCount == xq.count.total
          check gpList.len == xq.txDB.byGasTip.len
          check effGasTips.len == gpList.len
          check effGasTips == gpList.reversed

    # ---------------------------------

    block:
      const groupLen = 13
      let veryNoisy = noisy and false

      test &"Load/forward walk ID queue, " &
          &"deleting groups of at most {groupLen}":
        var
          xq = bcDB.toTxPool(txList, baseFee, noisy = noisy)
          seen: seq[TxItemRef]

        # Set txs to pseudo random status
        xq.setItemStatusFromInfo

        let itFn = proc(item: TxItemRef): bool =
                     xq.addOrFlushGroupwise(groupLen, seen, item, veryNoisy)
        check xq.txDB.verify.isOK
        elapNoisy.showElapsed("Forward delete-walk ID queue"):
          xq.pjaItemsApply(itFn, local = true)
          xq.pjaItemsApply(itFn, local = false)
          waitFor xq.jobCommit
        check xq.txDB.verify.isOK
        check seen.len == xq.count.total
        check seen.len < groupLen

      test &"Load/reverse walk ID queue, " &
          &"deleting in groups of at most {groupLen}":
        var
          xq = bcDB.toTxPool(txList, baseFee, noisy = noisy)
          seen: seq[TxItemRef]

        # Set txs to pseudo random status
        xq.setItemStatusFromInfo

        let itFn = proc(item: TxItemRef): bool =
                     xq.addOrFlushGroupwise(groupLen, seen, item, veryNoisy)
        check xq.txDB.verify.isOK
        elapNoisy.showElapsed("Revese delete-walk ID queue"):
          xq.pjaItemsApply(itFn, local = true)
          xq.pjaItemsApply(itFn, local = false)
          waitFor xq.jobCommit
        check xq.txDB.verify.isOK
        check seen.len == xq.count.total
        check seen.len < groupLen

    # ---------------------------------

    block:
      var
        count = 0
        xq = bcDB.toTxPool(itList = txList,
                           baseFee = baseFee,
                           maxRejects = txList.len,
                           noisy = noisy)
      # Set txs to pseudo random status
      xq.setItemStatusFromInfo

      let
        delLe = (effGasTips[0].int64 +
                   ((effGasTips[^1] - effGasTips[0]).int64 div 3)).GasPriceEx
        delMax = xq.txDB.byGasTip
                   .le(delLe).ge(AccountNonce.low).first.value.effGasTip

      test &"Load/delete with gas price less equal {delMax.toKMG}, " &
          &"out of price range {effGasTips[0].toKMG}..{effGasTips[^1].toKMG}":
        elapNoisy.showElapsed(&"Deleting gas tips less equal {delMax.toKMG}"):
          for itemList in xq.txDB.byGasTip.decItemList(maxPrice = delMax):
            for item in itemList.walkItems:
              count.inc
              check xq.txDB.dispose(item,txInfoErrUnspecified)
              check xq.txDB.verify.isOK
        check 0 < count
        check 0 < xq.count.total
        check count + xq.count.total == txList.len
        check xq.count.disposed == count

    block:
      var
        count = 0
        xq = bcDB.toTxPool(itList = txList,
                           baseFee = baseFee,
                           maxRejects = txList.len,
                           noisy = noisy)
      # Set txs to pseudo random status
      xq.setItemStatusFromInfo

      let
        delGe = (effGasTips[^1].int64 -
                   ((effGasTips[^1] - effGasTips[0]).int64 div 3)).GasPriceEx
        delMin = xq.txDB.byGasTip
                   .ge(delGe).ge(AccountNonce.low).first.value.effGasTip

      test &"Load/delete with gas price greater equal {delMin.toKMG}, " &
          &"out of price range {effGasTips[0].toKMG}..{effGasTips[^1].toKMG}":
        elapNoisy.showElapsed(
            &"Deleting gas tips greater than {delMin.toKMG}"):
          for itemList in xq.txDB.byGasTip.incItemList(minPrice = delMin):
            for item in itemList.walkItems:
              count.inc
              check xq.txDB.dispose(item,txInfoErrUnspecified)
              check xq.txDB.verify.isOK
        check 0 < count
        check 0 < xq.count.total
        check count + xq.count.total == txList.len
        check xq.count.disposed == count

    block:
      let
        newBaseFee = if 0 < baseFee: baseFee + 7.GasPrice
                     else:           42.GasPrice

      test &"Adjust baseFee to {newBaseFee} and back":
        var
          xq = bcDB.toTxPool(txList, baseFee, noisy = noisy)
          baseNonces: seq[AccountNonce] # second level sequence

        # Set txs to pseudo random status
        xq.setItemStatusFromInfo

        # register sequence of nonces
        for nonceList in xq.txDB.byGasTip.incNonceList:
          for itemList in nonceList.incItemList:
            baseNonces.add itemList.first.value.tx.nonce

        xq.txDB.baseFee = newBaseFee
        check xq.txDB.verify.isOK

        block:
          var
            seen: seq[Hash256]
            tips: seq[GasPriceEx]
          for nonceList in xq.txDB.byGasTip.incNonceList:
            tips.add nonceList.ge(AccountNonce.low).first.value.effGasTip
            for itemList in nonceList.incItemList:
              for item in itemList.walkItems:
                seen.add item.itemID
          check txList.len == xq.txDB.byItemID.nItems
          check txList.len == seen.len
          check tips != effGasTips              # values should have changed
          check seen != txList.mapIt(it.itemID) # order should have changed

        # change back
        xq.txDB.baseFee = baseFee
        check xq.txDB.verify.isOK

        block:
          var
            seen: seq[Hash256]
            tips: seq[GasPriceEx]
            nces: seq[AccountNonce]
          for nonceList in xq.txDB.byGasTip.incNonceList:
            tips.add nonceList.ge(AccountNonce.low).first.value.effGasTip
            for itemList in nonceList.incItemList:
              nces.add itemList.first.value.tx.nonce
              for item in itemList.walkItems:
                seen.add item.itemID
          check txList.len == xq.txDB.byItemID.nItems
          check txList.len == seen.len
          check tips == effGasTips              # values restored
          check nces == baseNonces              # values restored
          # note: txList[] will be equivalent to seen[] but not necessary
          #       the same


proc runTxPoolTests(noisy = true; baseFee = 0.GasPrice) =
  let
    baseInfo = if 0 < baseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Play with pool functions and primitives{baseInfo}":

    block:
      var
        gap: Time
        nItems: int
        xq = bcDB.toTxPool(timeGap = gap,
                           nRemoteGapItems = nItems,
                           itList = txList,
                           baseFee = baseFee,
                           remoteItemsPC = 35, # arbitrary
                           delayMSecs = 100,   # large enough to process
                           noisy = noisy)
      # Set txs to pseudo random status
      xq.setItemStatusFromInfo

      test &"Delete about {nItems} expired non-local transactions "&
          &"out of {xq.count.remote}":

        check 0 < nItems
        xq.lifeTime = getTime() - gap

        # evict and pick items from the wastbasket
        xq.pjaFlushRejects
        xq.pjaInactiveItemsEviction
        waitFor xq.jobCommit
        let deletedItems = xq.count.disposed

        check xq.count.local == okCount[true]
        check xq.verify.isOK # not: xq.txDB.verify
        check deletedItems == txList.len - xq.count.total

        # make sure that deletion was sort of expected
        let deleteExpextRatio = (deletedItems * 100 / nItems).int
        check deletedItemsRatioBandPC < deleteExpextRatio
        check deleteExpextRatio < (10000 div deletedItemsRatioBandPC)

    # ---------------------------------

    block:
      var
        xq = bcDB.toTxPool(txList, baseFee, noisy = noisy)
        maxAddr: EthAddress
        nAddrItems = 0

        nAddrRemoteItems = 0
        nAddrLocalItems = 0

        nAddrQueuedItems = 0
        nAddrPendingItems = 0
        nAddrStagedItems = 0

      # Set txs to pseudo random status
      xq.setItemStatusFromInfo

      let
        nLocalAddrs = toSeq(xq.getAccounts(local = true)).len
        nRemoteAddrs = toSeq(xq.txDB.bySender.walkNonceList(local = false)).len

      block:
        test "About half of transactions in largest address group are remotes":

          check 0 < nLocalAddrs
          check 0 < nRemoteAddrs

          # find address with max number of transactions
          for schedList in xq.txDB.bySender.walkSchedList:
            if nAddrItems < schedList.nItems:
              maxAddr = schedList.any.ge(AccountNonce.low).first.value.sender
              nAddrItems = schedList.nItems

          # requite mimimum => there is a status queue with at least 2 entries
          check 3 < nAddrItems

          # count the number of locals and remotes for this address
          nAddrRemoteItems =
                  xq.txDB.bySender.eq(maxAddr).eq(local = false).nItems
          nAddrLocalItems =
                  xq.txDB.bySender.eq(maxAddr).eq(local = true).nItems
          check nAddrRemoteItems + nAddrLocalItems == nAddrItems

          nAddrQueuedItems =
                  xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
          nAddrPendingItems =
                  xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
          nAddrStagedItems =
                  xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
          check nAddrQueuedItems +
                  nAddrPendingItems +
                  nAddrStagedItems == nAddrItems

          # make suke the random assignment made some sense
          check 0 < nAddrQueuedItems
          check 0 < nAddrPendingItems
          check 0 < nAddrStagedItems

          # make sure that local/remote ratio makes sense
          let localRemoteRatio =
             (((nAddrItems - nAddrRemoteItems) * 100) / nAddrRemoteItems).int
          check addrGroupLocalRemotePC < localRemoteRatio
          check localRemoteRatio < (10000 div addrGroupLocalRemotePC)

      block:
        test &"Reassign/move {nAddrRemoteItems} \"remote\" to " &
            &"{nAddrLocalItems} \"local\" items in largest address group " &
            &"with {nAddrItems} items":
          let
            nLocals = xq.count.local
            nRemotes = xq.count.remote

          xq.pjaRemoteToLocals(maxAddr)
          waitFor xq.jobCommit

          check xq.txDB.verify.isOK
          check xq.txDB.bySender.eq(maxAddr).eq(local = false).isErr

          check nLocals + nRemotes == xq.count.total
          check xq.count.local + xq.count.remote == xq.count.total
          check xq.count.local == nLocals + nAddrRemoteItems

          check nRemoteAddrs ==
            1 + toSeq(xq.txDB.bySender.walkNonceList(local = false)).len

          if 0 < nAddrLocalItems:
            check nLocalAddrs == toSeq(xq.getAccounts(local = true)).len
          else:
            check nLocalAddrs == 1 + toSeq(xq.getAccounts(local = true)).len

          check nAddrQueuedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
          check nAddrPendingItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
          check nAddrStagedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems

      # --------------------

      block:
        var
          fromNumItems = nAddrQueuedItems
          fromBucketInfo = "queued"
          fromBucket = txItemQueued
          toBucketInfo =  "pending"
          toBucket = txItemPending

        # find the largest from-bucket
        if fromNumItems < nAddrPendingItems:
          fromNumItems = nAddrPendingItems
          fromBucketInfo = "pending"
          fromBucket = txItemPending
          toBucketInfo = "staged"
          toBucket = txItemStaged
        if fromNumItems < nAddrStagedItems:
          fromNumItems = nAddrStagedItems
          fromBucketInfo = "staged"
          fromBucket = txItemStaged
          toBucketInfo = "queued"
          toBucket = txItemQueued

        let
          moveNumItems = fromNumItems div 2

        test &"Reassign {moveNumItems} of {fromNumItems} items "&
            &"from \"{fromBucketInfo}\" to \"{toBucketInfo}\"":
          check 0 < moveNumItems
          check 1 < fromNumItems

          var count = 0
          let ncList = xq.txDB.bySender.eq(maxAddr).eq(fromBucket).value.data
          block collect:
            for itemList in ncList.walkItemList:
              for item in itemList.walkItems:
                count.inc
                check xq.txDB.reassign(item, toBucket)
                if moveNumItems <= count:
                  break collect
          check xq.txDB.verify.isOK

          case fromBucket
          of txItemQueued:
            check nAddrQueuedItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
            check nAddrPendingItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
            check nAddrStagedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
          of txItemPending:
            check nAddrPendingItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
            check nAddrStagedItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
            check nAddrQueuedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
          else:
            check nAddrStagedItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
            check nAddrQueuedItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemQueued).nItems
            check nAddrStagedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems

      # --------------------

      block:
        var expect: (int,int)
        for schedList in xq.txDB.bySender.walkSchedList:
          expect[0] += schedList.eq(txItemPending).nItems
          expect[1] += schedList.eq(txItemQueued).nItems

        test &"Get global ({expect[0]},{expect[1]}) status via task manager":
          let status = xq.count
          check expect == (status.pending,status.queued)

      # --------------------

      block:
        test &"Delete locals from largest address group so it becomes empty":

          # clear waste basket
          xq.pjaFlushRejects
          waitFor xq.jobCommit

          var rejCount = 0
          let addrLocals = xq.txDB.bySender.eq(maxAddr)
                                           .eq(local = true).value.data
          for itemList in addrLocals.walkItemList:
            for item in itemList.walkItems:
              check xq.txDB.dispose(item,txInfoErrUnspecified)
              rejCount.inc

          check nLocalAddrs == 1 + toSeq(xq.getAccounts(local = true)).len
          check xq.count.disposed == rejCount
          check xq.txDB.verify.isOK


proc runTxPackerTests(noisy = true) =

  suite &"TxPool: Block packer tests":
    let
      remList = txList.mapIt(it.toRemote) # remotes only list
    var
      ntBaseFee = 0.GasPrice
      ntNextFee = 0.GasPrice

    test &"Calculate some non-trivial base fee":
      var
        xq = bcDB.toTxPool(txList, 0.GasPrice, noisy = noisy)
      let
        minKey = max(0, xq.txDB.byGasTip.ge(GasPriceEx.low).value.key.int64)
        lowKey = xq.txDB.byGasTip.gt(minKey.GasPriceEx).value.key.uint64
        highKey = xq.txDB.byGasTip.le(GasPriceEx.high).value.key.uint64
        keyRange = highKey - lowKey
        keyStep = max(1u64, keyRange div 500_000)

      # what follows is a rather crude partitioning so that
      # * ntBaseFee partititions non-zero numbers of queued and pending txs
      # * ntNextFee decreases the number of pending txs
      ntBaseFee = (lowKey + keyStep).GasPrice

      # the following might throw an exception if the table is de-generated
      var nextKey = ntBaseFee
      for _ in [1, 2, 3]:
        let rcNextKey = xq.txDB.byGasTip.gt(nextKey.GasPriceEx)
        check rcNextKey.isOK
        nextKey = rcNextKey.value.key.uint64.GasPrice

      ntNextFee = nextKey + keyStep.GasPrice

      # of course ...
      check ntBaseFee < ntNextFee

    block:
      var
        xq = bcDB.toTxPool(remList, baseFee = ntBaseFee, noisy = noisy)
        xr = bcDB.toTxPool(remList, baseFee = ntNextFee, noisy = noisy)
      block:
        let
          queued = xq.count.queued
          pending = xq.count.pending

        test &"Load \"remote\" txs with baseFee={ntBaseFee}, "&
            &"queued/pending={queued}/{pending}":

          check 0 < queued
          check 0 < pending
          check xq.count.remote == txList.len
          check xq.count.disposed == 0

      block:
        let
          queued = xr.count.queued
          pending = xr.count.pending

        test &"Re-org txs queues setting baseFee={ntNextFee}, "&
            &"queued/pending={queued}/{pending}":

          check 0 < queued
          check 0 < pending
          check xr.count.remote == txList.len
          check xr.count.disposed == 0

          check xq.getBaseFee == ntBaseFee
          xq.setBaseFee(ntNextFee, true)
          check xq.getBaseFee == ntNextFee

          xq.pjaUpdatePending(force = true)
          waitFor xq.jobCommit

          # now, xq should look like xr
          check xq.count == xr.count

      block:
        # get some value below the middle
        let
          packPrice = ((minGasPrice + maxGasPrice).uint64 div 3).GasPrice
          lowerPrice = minGasPrice + 1.GasPrice

        test &"Staging and packing txs, baseFee=0 minPrice={packPrice} "&
            &"targetBlockSize={xq.dbHead.trgGasLimit}":

          # verify that the test does not degenerate
          check 0 < minGasPrice
          check minGasPrice < maxGasPrice

          # ignore base limit so that the `packPrice` below becomes effective
          xq.setBaseFee(0.GasPrice, true)
          check xq.getBaseFee == 0.GasPrice

          # set minimum target price
          xq.setMinPlGasPrice(packPrice)
          xq.setAlgoSelector(algoPackTryHarder) # try setting some strategy

          noisy.say "*** status before 1st staging ", xq.count

          xq.pjaUpdateStaged
          waitFor xq.jobCommit

          # verify that the test does not degenerate
          check 0 < xq.count.staged
          check xq.txDB.flushRejects[1] == 0

          noisy.say "*** status after 1st staging ", xq.count

          # assemble block
          let total = xq.nextBlock
          noisy.say "*** 1st block generated, size=", total
          noisy.say "*** final status ", xq.count

          check 0 < total
          check 0 < xq.count.disposed # number of packed txs
          check xq.count.disposed == xq.getBlock.txs.len

        test &"Continue staging after lowering minPrice={lowerPrice}, "&
            "then pack txs for another block":

          # verify that the test does not degenerate
          check 0 < lowerPrice
          check lowerPrice < packPrice

          # set  minimum target price
          xq.setMinPlGasPrice(lowerPrice)

          xq.pjaUpdateStaged
          waitFor xq.jobCommit

          # verify that the test does not degenerate
          check 0 < xq.count.staged
          check xq.txDB.flushRejects[1] == 0

          noisy.say "*** status after 2nd staging ", xq.count

          # assemble block
          let total = xq.nextBlock
          noisy.say "*** 2nd block generated, size=", total
          noisy.say "*** final status ", xq.count

          check 0 < total
          check 0 < xq.count.disposed # number of packed txs
          check xq.count.disposed == xq.getBlock.txs.len

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc txPoolMain*(noisy = defined(debug)) =
  const baseFee = 42.GasPrice
  noisy.runTxLoader(baseFee)
  noisy.runTxBaseTests(baseFee)
  noisy.runTxPoolTests(baseFee)
  noisy.runTxPackerTests

when isMainModule:
  proc localDir(c: CaptureSpecs): CaptureSpecs =
    result = c
    result.dir = "."
  const
    noisy = defined(debug)
    baseFee = 42.GasPrice
    capts0: CaptureSpecs =
                goerliCapture.localDir
    capts1: CaptureSpecs = (
                GoerliNet, "/status", "goerli504192.txt.gz", 30000, 1500)
    capts2: CaptureSpecs = (
                MainNet, "/status", "mainnet843841.txt.gz", 30000, 1500)

  noisy.runTxLoader(baseFee, capture = capts1)
  noisy.runTxBaseTests(baseFee)
  noisy.runTxPoolTests(baseFee)
  true.runTxPackerTests

  #noisy.runTxLoader(baseFee, dir = ".")
  #noisy.runTxPoolTests(baseFee)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
