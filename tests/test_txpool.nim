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
  std/[algorithm, os, random, sequtils, strformat, strutils, tables, times],
  ../nimbus/chain_config,
  ../nimbus/config,
  ../nimbus/db/db_chain,
  ../nimbus/utils/tx_pool,
  ../nimbus/utils/tx_pool/tx_item,
  ./test_txpool/[helpers, setup, sign_helper],
  chronos,
  eth/[common, keys, p2p],
  stew/sorted_set,
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
    file: "replay" / "goerli51840.txt.gz",
    numBlocks: 18000,
    numTxs: 728) # maximum that can be used from this dump

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
  statCount: array[TxItemStatus,int] # per status bucket

  txList: seq[TxItemRef]
  effGasTips: seq[GasPriceEx]
  gasTipCaps: seq[GasPrice]

  # running block chain
  bcDB: BaseChainDB

  # collected accounts from block chain database transactions
  txAccounts: seq[EthAddress]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc randStatusRatios: seq[int] =
  for n in 1 .. statCount.len:
    let
      inx = (n mod statCount.len).TxItemStatus
      prv = (n - 1).TxItemStatus
    if statCount[inx] == 0:
      result.add int.high
    else:
      result.add (statCount[prv] * 100 / statCount[inx]).int

proc randStatus: TxItemStatus =
  result = prng.rand(TxItemStatus.high.ord).TxItemStatus
  statCount[result].inc

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
      let xpLen = xp.nItems.total
      noisy.say "*** updateSeen: deleting ", seen.mapIt($it.itemID).join(" ")
      for item in seen:
        doAssert xp.txDB.dispose(item,txInfoErrUnspecified)
      doAssert xpLen == seen.len + xp.nItems.total
      doAssert seen.len == xp.nItems.disposed
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
        xp = bcDB.toTxPool(accounts = txAccounts,
                           file = file,
                           getStatus = randStatus,
                           loadBlocks = capture.numBlocks,
                           loadTxs = capture.numTxs,
                           baseFee = baseFee,
                           noisy = veryNoisy)

      # Set txs to pseudo random status
      check xp.verify.isOK
      xp.setItemStatusFromInfo

      # Boundary conditions regarding nonces might be violated by running
      # setItemStatusFromInfo() => xp.txDB.verify() rather than xp.verify()
      check xp.txDB.verify.isOK

      check txList.len == 0
      check xp.nItems.disposed == 0

      noisy.say "***",
         "Latest item: <", xp.txDB.byItemID.last.value.data.info, ">"

      # make sure that the block chain was initialised
      check capture.numBlocks.u256 <= bcDB.getCanonicalHead.blockNumber

      check xp.nItems.total == foldl(statCount.toSeq, a+b)
      #                        ^^^ sum up statCount[] values

      # make sure that PRNG did not go bonkers
      for statusRatio in randStatusRatios():
        check randInitRatioBandPC < statusRatio
        check statusRatio < (10000 div randInitRatioBandPC)

      # Note: expecting enough transactions in the `goerliCapture` file
      check xp.nItems.total == capture.numTxs

      # Load txList[]
      txList = xp.toItems
      check txList.len == xp.nItems.total

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
            if item.tx.gasPrice.GasPriceEx < minGasPrice and
               0 < item.tx.gasPrice:
              minGasPrice = item.tx.gasPrice.GasPrice
            if maxGasPrice < item.tx.gasPrice.GasPrice:
              maxGasPrice = item.tx.gasPrice.GasPrice

      check minGasPrice <= maxGasPrice
      check gasTipCaps.len == xp.txDB.byTipCap.len

    test &"Concurrent job processing example":
      var log = ""

      # This test does not verify anything but rather shows how the pool
      # primitives could be used in an async context.

      proc delayJob(xp: TxPoolRef; waitMs: int) {.async.} =
        let n = xp.nJobsWaiting
        xp.job(TxJobDataRef(kind: txJobNone))
        xp.job(TxJobDataRef(kind: txJobNone))
        xp.job(TxJobDataRef(kind: txJobNone))
        log &= " wait-" & $waitMs & "-" & $(xp.nJobsWaiting - n)
        await chronos.milliseconds(waitMs).sleepAsync
        xp.jobCommit
        log &= " done-" & $waitMs

      # run async jobs, completion should be sorted by timeout argument
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

      # Cannot rely on boundary conditions regarding nonces. So xp.verify()
      # will not work here => xp.txDB.verify()
      check xp.txDB.verify.isOK


proc runTxBaseTests(noisy = true; baseFee = 0.GasPrice) =

  let
    elapNoisy = false
    baseInfo = if 0 < baseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Play with queues and lists{baseInfo}":

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

        check xq.txDB.verify.isOK
        elapNoisy.showElapsed("Forward delete-walk ID queue"):
          for item in xq.txDB.byItemID.nextValues:
            if not xq.addOrFlushGroupwise(groupLen, seen, item, veryNoisy):
              break
        check xq.txDB.verify.isOK
        check seen.len == xq.nItems.total
        check seen.len < groupLen

      test &"Load/reverse walk ID queue, " &
          &"deleting in groups of at most {groupLen}":
        var
          xq = bcDB.toTxPool(txList, baseFee, noisy = noisy)
          seen: seq[TxItemRef]

        # Set txs to pseudo random status
        xq.setItemStatusFromInfo

        check xq.txDB.verify.isOK
        elapNoisy.showElapsed("Revese delete-walk ID queue"):
          for item in xq.txDB.byItemID.nextValues:
            if not xq.addOrFlushGroupwise(groupLen, seen, item, veryNoisy):
              break
        check xq.txDB.verify.isOK
        check seen.len == xq.nItems.total
        check seen.len < groupLen

    # ---------------------------------

    block:
      var
        count = 0
        xq = bcDB.toTxPool(txList, baseFee, noisy)
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
        check 0 < xq.nItems.total
        check count + xq.nItems.total == txList.len
        check xq.nItems.disposed == count

    block:
      var
        count = 0
        xq = bcDB.toTxPool(txList, baseFee, noisy)
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
        check 0 < xq.nItems.total
        check count + xq.nItems.total == txList.len
        check xq.nItems.disposed == count

    block:
      let
        newBaseFee = if 0 < baseFee: baseFee + 7.GasPrice
                     else:           42.GasPrice

      test &"Adjust baseFee to {newBaseFee} and back":
        var
          xq = bcDB.toTxPool(txList, baseFee, noisy = noisy)
          baseNonces: seq[AccountNonce] # second level sequence

        # Set txs to pseudo random status (database will violate
        # boundary contitions on nonces)
        xq.setItemStatusFromInfo

        # register sequence of nonces
        for nonceList in xq.txDB.byGasTip.incNonceList:
          for itemList in nonceList.incItemList:
            baseNonces.add itemList.first.value.tx.nonce

        xq.baseFee = newBaseFee
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
          check txList.len == xq.txDB.byItemID.len
          check txList.len == seen.len
          check tips != effGasTips              # values should have changed
          check seen != txList.mapIt(it.itemID) # order should have changed

        # change back
        xq.baseFee = baseFee
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
          check txList.len == xq.txDB.byItemID.len
          check txList.len == seen.len
          check tips == effGasTips              # values restored
          check nces == baseNonces              # values restored
          # note: txList[] will be equivalent to seen[] but not necessary
          #       the same


proc runTxPoolTests(noisy = true; baseFee = 0.GasPrice) =
  let baseInfo = if 0 < baseFee: &" with baseFee={baseFee}" else: ""

  suite &"TxPool: Play with pool functions and primitives{baseInfo}":

    block:
      var
        xq = TxPoolRef.init(bcDB)
        testTxs: array[5,(TxItemRef,Transaction,Transaction)]

      test &"Superseding txs with sender and nonce variants":
        var
          testInx = 0
        let
          testBump = xq.priceBump
          lastBump = testBump - 1 # implies underpriced item

        # load a set of suitable txs into testTxs[]
        for n in 0 ..< txList.len:
          let
            item = txList[n]
            bump = if testInx < testTxs.high: testBump else: lastBump
            rc = item.txModPair(testInx,bump.int)
          if not rc[0].isNil:
            testTxs[testInx] = rc
            testInx.inc
            if testTxs.high < testInx:
              break

        # verify that test does not degenerate
        check testInx == testTxs.len
        check 0 < lastBump # => 0 < testBump

        # insert some txs
        for triple in testTxs:
          let item = triple[0]
          var tx = triple[1]
          xq.jobAddTx(tx, item.info)
        xq.jobCommit

        check xq.nItems.total == testTxs.len
        check xq.nItems.disposed == 0
        let infoLst = testTxs.toSeq.mapIt(it[0].info).sorted
        check infoLst == xq.toItems.toSeq.mapIt(it.info).sorted

        # re-insert modified transactions
        for triple in testTxs:
          let item = triple[0]
          var tx = triple[2]
          xq.jobAddTx(tx, "alt " & item.info)
        xq.jobCommit

        check xq.nItems.total == testTxs.len
        check xq.nItems.disposed == testTxs.len

        # last update item was underpriced, so it must not have been
        # replaced
        var altLst = testTxs.toSeq.mapIt("alt " & it[0].info)
        altLst[^1] = testTxs[^1][0].info
        check altLst.sorted == xq.toItems.toSeq.mapIt(it.info).sorted

      test &"Deleting tx => also delete higher nonces":

        let
          # From the data base, get the one before last item. This was
          # replaced earlier by the second transaction in the triple, i.e.
          # testTxs[^2][2]. FYI, the last transaction is testTxs[^1][1] as
          # it could not be replaced earlier by testTxs[^1][2].
          item = xq.getItem(testTxs[^2][2].itemID).value

          nWasteBasket = xq.nItems.disposed

        # make sure the test makes sense, nonces were 0 ..< testTxs.len
        check (item.tx.nonce + 2).int == testTxs.len

        xq.disposeItems(item)

        check xq.nItems.total + 2 == testTxs.len
        check nWasteBasket + 2 == xq.nItems.disposed

    # --------------------------

    block:
      var
        gap: Time
        nItems: int
        xq = bcDB.toTxPool(timeGap = gap,
                           nGapItems = nItems,
                           itList = txList,
                           baseFee = baseFee,
                           itemsPC = 35,       # arbitrary
                           delayMSecs = 100,   # large enough to process
                           noisy = noisy)
      # Set txs to pseudo random status. Note that this functon will cause
      # a violation of boundary conditions regarding nonces. So database
      # integrily check needs xq.txDB.verify() rather than xq.verify().
      xq.setItemStatusFromInfo

      test &"Delete about {nItems} expired txs out of {xq.nItems.total}":

        check 0 < nItems
        xq.lifeTime = getTime() - gap
        xq.flags = xq.flags + {algoAutoDisposeUnpacked, algoAutoDisposePacked}

        # evict and pick items from the wastbasket
        let
          disposedBase = xq.nItems.disposed
          evictedBase = evictionMeter.value
          impliedBase = impliedEvictionMeter.value
        xq.jobCommit(true)
        let
          disposedItems = xq.nItems.disposed - disposedBase
          evictedItems = (evictionMeter.value - evictedBase).int
          impliedItems = (impliedEvictionMeter.value - impliedBase).int

        check xq.txDB.verify.isOK
        check disposedItems + disposedBase + xq.nItems.total == txList.len
        check 0 < evictedItems
        check evictedItems <= disposedItems
        check disposedItems == evictedItems + impliedItems

        # make sure that deletion was sort of expected
        let deleteExpextRatio = (evictedItems * 100 / nItems).int
        check deletedItemsRatioBandPC < deleteExpextRatio
        check deleteExpextRatio < (10000 div deletedItemsRatioBandPC)

    # --------------------

    block:
      var
        xq = bcDB.toTxPool(txList, baseFee, noisy)
        maxAddr: EthAddress
        nAddrItems = 0

        nAddrPendingItems = 0
        nAddrStagedItems = 0
        nAddrPackedItems = 0

        fromNumItems = nAddrPendingItems
        fromBucketInfo = "pending"
        fromBucket = txItemPending
        toBucketInfo =  "staged"
        toBucket = txItemStaged

      # Set txs to pseudo random status
      xq.setItemStatusFromInfo

      # find address with max number of transactions
      for schedList in xq.txDB.bySender.walkSchedList:
        if nAddrItems < schedList.nItems:
          maxAddr = schedList.any.ge(AccountNonce.low).value.data.sender
          nAddrItems = schedList.nItems

      # count items
      nAddrPendingItems = xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
      nAddrStagedItems = xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
      nAddrPackedItems = xq.txDB.bySender.eq(maxAddr).eq(txItemPacked).nItems

      # find the largest from-bucket
      if fromNumItems < nAddrStagedItems:
        fromNumItems = nAddrStagedItems
        fromBucketInfo = "staged"
        fromBucket = txItemStaged
        toBucketInfo = "packed"
        toBucket = txItemPacked
      if fromNumItems < nAddrPackedItems:
        fromNumItems = nAddrPackedItems
        fromBucketInfo = "packed"
        fromBucket = txItemPacked
        toBucketInfo = "pending"
        toBucket = txItemPending

      let moveNumItems = fromNumItems div 2

      test &"Reassign {moveNumItems} of {fromNumItems} items "&
          &"from \"{fromBucketInfo}\" to \"{toBucketInfo}\"":

        # requite mimimum => there is a status queue with at least 2 entries
        check 3 < nAddrItems

        check nAddrPendingItems +
                nAddrStagedItems +
                nAddrPackedItems == nAddrItems

        check 0 < moveNumItems
        check 1 < fromNumItems

        var count = 0
        let ncList = xq.txDB.bySender.eq(maxAddr).eq(fromBucket).value.data
        block collect:
          for item in ncList.walkItems:
            count.inc
            check xq.txDB.reassign(item, toBucket)
            if moveNumItems <= count:
              break collect
        check xq.txDB.verify.isOK

        case fromBucket
        of txItemPending:
          check nAddrPendingItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
          check nAddrStagedItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
          check nAddrPackedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPacked).nItems
        of txItemStaged:
          check nAddrStagedItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemStaged).nItems
          check nAddrPackedItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPacked).nItems
          check nAddrPendingItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
        else:
          check nAddrPackedItems - moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPacked).nItems
          check nAddrPendingItems + moveNumItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPending).nItems
          check nAddrPackedItems ==
                    xq.txDB.bySender.eq(maxAddr).eq(txItemPacked).nItems

      # --------------------

      var expect: (int,int,int)
      for schedList in xq.txDB.bySender.walkSchedList:
        expect[0] += schedList.eq(txItemPending).nItems
        expect[1] += schedList.eq(txItemStaged).nItems
        expect[2] += schedList.eq(txItemPacked).nItems

      test &"Verify #items per bucket ({expect[0]},{expect[1]},{expect[2]})":
        let status = xq.nItems
        check expect == (status.pending,status.staged,status.packed)

      test "Recycling from waste basket":

        let
          basketPrefill = xq.nItems.disposed
          numDisposed = min(50,txList.len)

          # make sure to work on a copy of the pivot item (to see changes)
          thisItem = xq.getItem(txList[^numDisposed].itemID).value.dup

        # move to wastebasket
        xq.maxRejects = txList.len
        for n in 1 .. numDisposed:
          # use from top avoiding extra deletes (higer nonces per account)
          xq.disposeItems(txList[^n])

        # make sure that the pivot item is in the waste basket
        check xq.getItem(thisItem.itemID).isErr
        check xq.txDB.byRejects.hasKey(thisItem.itemID)
        check basketPrefill + numDisposed == xq.nItems.disposed
        check txList.len == xq.nItems.total + xq.nItems.disposed

        # re-add item
        xq.jobAddTx(thisItem.tx)
        xq.jobCommit

        # verify that the pivot item was moved out from the waste basket
        check not xq.txDB.byRejects.hasKey(thisItem.itemID)
        check basketPrefill + numDisposed == xq.nItems.disposed + 1
        check txList.len == xq.nItems.total + xq.nItems.disposed

        # verify that a new item was derived from the waste basket pivot item
        let wbItem = xq.getItem(thisItem.itemID).value
        check thisItem.info == wbItem.info
        check thisItem.timestamp < wbItem.timestamp


proc runTxPackerTests(noisy = true) =

  suite &"TxPool: Block packer tests":
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
      # * ntBaseFee partititions non-zero numbers of pending and staged txs
      # * ntNextFee decreases the number of staged txs
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
        xq = bcDB.toTxPool(txList, ntBaseFee, noisy)
        xr = bcDB.toTxPool(txList, ntNextFee, noisy)
      block:
        let
          pending = xq.nItems.pending
          staged = xq.nItems.staged
          packed = xr.nItems.packed

        test &"Load txs with baseFee={ntBaseFee}, "&
          &"buckets={pending}/{staged}/{packed}":

          check 0 < pending
          check 0 < staged
          check xq.nItems.total == txList.len
          check xq.nItems.disposed == 0

      block:
        let
          pending = xr.nItems.pending
          staged = xr.nItems.staged
          packed = xr.nItems.packed

        test &"Re-org txs previous buckets setting baseFee={ntNextFee}, "&
            &"buckets={pending}/{staged}/{packed}":

          check 0 < pending
          check 0 < staged
          check xr.nItems.total == txList.len
          check xr.nItems.disposed == 0

          check xq.baseFee == ntBaseFee
          xq.baseFee = ntNextFee
          check xq.baseFee == ntNextFee

          # having the same set of txs, setting the xq database to the same
          # base fee as the xr one, the bucket fills of both database must
          # be the same after re-org
          xq.flags = xq.flags + {algoAutoUpdateBuckets}
          xq.jobCommit(forceMaintenance = true)

          # now, xq should look like xr
          check xq.verify.isOK
          check xq.nItems == xr.nItems

      block:
        # get some value below the middle
        let
          packPrice = ((minGasPrice + maxGasPrice).uint64 div 3).GasPrice
          lowerPrice = minGasPrice + 1.GasPrice

        test &"Packing txs, baseFee=0 minPrice={packPrice} "&
            &"targetBlockSize={xq.dbHead.trgGasLimit}":

          # verify that the test does not degenerate
          check 0 < minGasPrice
          check minGasPrice < maxGasPrice

          # ignore base limit so that the `packPrice` below becomes effective
          xq.baseFee = 0.GasPrice
          check xq.baseFee == 0.GasPrice
          check xq.nItems.disposed == 0

          # set minimum target price
          xq.minPreLondonGasPrice = packPrice
          check xq.minPreLondonGasPrice == packPrice

          # employ packer
          xq.flags = xq.flags + {algoPackTryHarder, algoAutoTxsPacker}
          xq.jobCommit(forceMaintenance = true)
          check xq.verify.isOK

          # verify that the test did not degenerate
          check 0 < xq.gasTotals.packed
          check xq.nItems.disposed == 0

          # assemble block from `packed` bucket
          let total = foldl(xq.ethBlock.txs.mapIt(it.gasLimit), a+b)
          check xq.gasTotals.packed == total

          noisy.say "***", "1st bLock size=", total, " stats=", xq.nItems.pp

        test &"Clear and re-pack bucket":
          let saveState = xq.ethBlock.txs.mapIt((it.nonce,it.gasLimit))
          check 0 < saveState.len
          check 0 < xq.nItems.packed

          # flush packed bucket and trigger re-pack
          xq.triggerPacker(clear = true)
          check xq.nItems.packed == 0
          check xq.verify.isOK

          # re-pack bucket
          xq.jobCommit(forceMaintenance = true)
          check xq.verify.isOK

          check saveState == xq.ethBlock.txs.mapIt((it.nonce,it.gasLimit))

        test &"Delete item and re-pack bucket/w lower minPrice={lowerPrice}":
          # verify that the test does not degenerate
          check 0 < lowerPrice
          check lowerPrice < packPrice
          check 0 < xq.nItems.packed

          let
            saveStats = xq.nItems
            lastItem = xq.txDB.byStatus
              .eq(txItemPacked).le(maxEthAddress).le(AccountNonce.high)
              .value.data

          # delete last item from packed bucket
          xq.disposeItems(lastItem)
          check xq.verify.isOK

          # set new minimum target price
          xq.minPreLondonGasPrice = lowerPrice
          check xq.minPreLondonGasPrice == lowerPrice

          # re-pack bucket, packer needs extra trigger because there is
          # not necessarily a buckets re-org resulting in a change
          xq.triggerPacker
          xq.jobCommit(forceMaintenance = true)
          check xq.verify.isOK

          let
            newTotal = foldl(xq.ethBlock.txs.mapIt(it.gasLimit), a+b)
            newStats = xq.nItems
            newItem = xq.txDB.byStatus
              .eq(txItemPacked).le(maxEthAddress).le(AccountNonce.high)
              .value.data

          # for sanity assert the obvoius
          check 0 < xq.gasTotals.packed
          check xq.gasTotals.packed == newTotal

          # verify incremental packing
          check lastItem.info != newItem.info
          check saveStats.packed <= newStats.packed

          noisy.say "***", "2st bLock size=", newTotal, " stats=", newStats.pp

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
  import ../nimbus/db/accounts_cache

  proc showAccounts =
    var senders = txAccounts.mapIt((it,true)).toTable
    for item in txList:
      if not senders.hasKey(item.sender):
        senders[item.sender] = false
    let
      header = bcDB.getCanonicalHead
      cache = AccountsCache.init(bcDB.db, header.stateRoot, bcDB.pruneTrie)
    for (sender,known) in senders.pairs:
      let
        isKnown = if known: " known" else: " new  "
        id = sender.toHex[30..39]
        nonce = cache.getNonce(sender)
        balance = cache.getBalance(sender)
      echo &">>> {id} {isKnown} balance={balance} nonce={nonce}"

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

  noisy.runTxLoader(baseFee, capture = capts0)
  noisy.runTxBaseTests(baseFee)
  noisy.runTxPoolTests(baseFee)
  noisy.runTxPackerTests

  #noisy.runTxLoader(baseFee, dir = ".")
  #noisy.runTxPoolTests(baseFee)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
