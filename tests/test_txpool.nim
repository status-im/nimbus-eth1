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
  ../nimbus/core/chain, # must be early (compilation annoyance)
  ../nimbus/common/common,
  ../nimbus/core/clique/clique_sealer,
  ../nimbus/core/[clique, executor, casper, tx_pool, tx_pool/tx_item],
  ../nimbus/[config, vm_state, vm_types],
  ./test_txpool/[helpers, setup, sign_helper],
  ./test_txpool2,
  chronos,
  eth/[keys, p2p],
  stew/[keyed_queue, sorted_set],
  stint,
  unittest2

type
  CaptureSpecs = tuple
    network: NetworkID
    file: string
    numBlocks, minBlockTxs, numTxs: int

const
  prngSeed = 42

  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests"/"replay", "nimbus-eth1-blobs"/"replay"]

  goerliCapture: CaptureSpecs = (
    network: GoerliNet,
    file: "goerli68161.txt.gz",
    numBlocks: 22000,  # block chain prequel
    minBlockTxs: 300,  # minimum txs in imported blocks
    numTxs:      840)  # txs following (not in block chain)

  loadSpecs = goerliCapture

  # 75% <= #local/#remote <= 1/75%
  # note: by law of big numbers, the ratio will exceed any upper or lower
  #       on a +1/-1 random walk if running long enough (with expectation
  #       value 0)
  randInitRatioBandPC = 75

  # 95% <= #remote-deleted/#remote-present <= 1/95%
  deletedItemsRatioBandPC = 95

  # With a large enough block size, decreasing it should not decrease the
  # profitability (very much) as the the number of blocks availabe increases
  # (and a better choice might be available?) A good value for the next
  # parameter should be above 100%.
  decreasingBlockProfitRatioPC = 92

  # Make some percentage of the accounts local accouns.
  accountExtractPC = 10

var
  minGasPrice = GasPrice.high
  maxGasPrice = GasPrice.low

  prng = prngSeed.initRand

  # To be set up in runTxLoader()
  statCount: array[TxItemStatus,int] # per status bucket

  txList: seq[TxItemRef]
  effGasTips: seq[GasPriceEx]

  # Running block chain
  bcCom: CommonRef

  # Accounts to be considered local
  localAccounts: seq[EthAddress]

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

proc runTxLoader(noisy = true; capture = loadSpecs) =
  let
    elapNoisy = noisy
    veryNoisy = false # noisy
    fileInfo = capture.file.splitFile.name.split(".")[0]
    filePath = capture.file.findFilePath(baseDir,repoDir).value

  # Reset/initialise
  statCount.reset
  txList.reset
  effGasTips.reset
  bcCom = capture.network.blockChainForTesting

  suite &"TxPool: Transactions from {fileInfo} capture":
    var
      xp: TxPoolRef
      nTxs: int

    test &"Import {capture.numBlocks.toKMG} blocks + {capture.minBlockTxs} txs"&
        &" and collect {capture.numTxs} txs for pooling":

      elapNoisy.showElapsed("Total collection time"):
        (xp, nTxs) = bcCom.toTxPool(file = filePath,
                                   getStatus = randStatus,
                                   loadBlocks = capture.numBlocks,
                                   minBlockTxs = capture.minBlockTxs,
                                   loadTxs = capture.numTxs,
                                   noisy = veryNoisy)

      # Extract some of the least profitable accounts and hold them so
      # they could be made local at a later stage
      let
        accr = xp.accountRanks
        nExtract = (accr.remote.len * accountExtractPC + 50) div 100
      localAccounts = accr.remote[accr.remote.len - nExtract .. ^1]

      # Make sure that sample extraction from file was ok
      check capture.minBlockTxs <= nTxs
      check capture.numTxs == xp.nItems.total

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
      check capture.numBlocks.u256 <= bcCom.db.getCanonicalHead.blockNumber

      check xp.nItems.total == foldl(@[0]&statCount.toSeq, a+b)
      #                        ^^^ sum up statCount[] values

      # make sure that PRNG did not go bonkers
      for statusRatio in randStatusRatios():
        check randInitRatioBandPC < statusRatio
        check statusRatio < (10000 div randInitRatioBandPC)

      # Load txList[]
      txList = xp.toItems
      check txList.len == xp.nItems.total

      elapNoisy.showElapsed("Load min/max gas prices"):
        for item in txList:
          if item.tx.gasPrice < minGasPrice and 0 < item.tx.gasPrice:
            minGasPrice = item.tx.gasPrice.GasPrice
          if maxGasPrice < item.tx.gasPrice.GasPrice:
            maxGasPrice = item.tx.gasPrice.GasPrice

      check 0.GasPrice <= minGasPrice
      check minGasPrice <= maxGasPrice


proc runTxPoolTests(noisy = true) =
  let elapNoisy = false

  suite &"TxPool: Play with pool functions and primitives":

    block:
      const groupLen = 13
      let veryNoisy = noisy and false

      test &"Load/forward walk ID queue, " &
          &"deleting groups of at most {groupLen}":
        var
          xq = bcCom.toTxPool(txList, noisy = noisy)
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
          xq = bcCom.toTxPool(txList, noisy = noisy)
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

    block:
      var
        xq = TxPoolRef.new(bcCom,testAddress)
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
          xq.add(triple[1], triple[0].info)

        check xq.nItems.total == testTxs.len
        check xq.nItems.disposed == 0
        let infoLst = testTxs.toSeq.mapIt(it[0].info).sorted
        check infoLst == xq.toItems.toSeq.mapIt(it.info).sorted

        # re-insert modified transactions
        for triple in testTxs:
          xq.add(triple[2], "alt " & triple[0].info)

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
        xq = bcCom.toTxPool(timeGap = gap,
                           nGapItems = nItems,
                           itList = txList,
                           itemsPC = 35,       # arbitrary
                           delayMSecs = 100,   # large enough to process
                           noisy = noisy)

      # Set txs to pseudo random status. Note that this functon will cause
      # a violation of boundary conditions regarding nonces. So database
      # integrily check needs xq.txDB.verify() rather than xq.verify().
      xq.setItemStatusFromInfo

      test &"Auto delete about {nItems} expired txs out of {xq.nItems.total}":

        # Make sure that the test did not collapse
        check 0 < nItems
        xq.lifeTime = getTime() - gap
        xq.flags = xq.flags + {autoZombifyPacked}

        # Evict and pick items from the wastbasket
        let
          disposedBase = xq.nItems.disposed
          evictedBase = evictionMeter.value
          impliedBase = impliedEvictionMeter.value

        # Zombify the items that are older than the artificial time gap. The
        # move to the waste basket takes place with the `xq.add()` directive
        # (which is empty as there are no new txs.)
        xq.add @[]

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
        xq = bcCom.toTxPool(txList, noisy = noisy)
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
      for (address,nonceList) in xq.txDB.incAccount:
        if nAddrItems < nonceList.nItems:
          maxAddr = address
          nAddrItems = nonceList.nItems

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
        let nonceList = xq.txDB.bySender.eq(maxAddr).eq(fromBucket).value.data
        block collect:
          for item in nonceList.incNonce:
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

      let expect = (
        xq.txDB.byStatus.eq(txItemPending).nItems,
        xq.txDB.byStatus.eq(txItemStaged).nItems,
        xq.txDB.byStatus.eq(txItemPacked).nItems)

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
        xq.add(thisItem.tx)

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
        feesList = SortedSet[GasPriceEx,bool].init()

      # provide a sorted list of gas fees
      for item in txList:
        discard feesList.insert(item.tx.effectiveGasTip(0.GasPrice))

      let
        minKey = max(0, feesList.ge(GasPriceEx.low).value.key.int64)
        lowKey = feesList.gt(minKey.GasPriceEx).value.key.uint64
        highKey = feesList.le(GasPriceEx.high).value.key.uint64
        keyRange = highKey - lowKey
        keyStep = max(1u64, keyRange div 500_000)

      # what follows is a rather crude partitioning so that
      # * ntBaseFee partititions non-zero numbers of pending and staged txs
      # * ntNextFee decreases the number of staged txs
      ntBaseFee = (lowKey + keyStep).GasPrice

      # the following might throw an exception if the table is de-generated
      var nextKey = ntBaseFee
      for _ in [1, 2, 3]:
        let rcNextKey = feesList.gt(nextKey.GasPriceEx)
        check rcNextKey.isOK
        nextKey = rcNextKey.value.key.uint64.GasPrice

      ntNextFee = nextKey + keyStep.GasPrice

      # of course ...
      check ntBaseFee < ntNextFee

    block:
      var
        xq = bcCom.toTxPool(txList, ntBaseFee, noisy = noisy)
        xr = bcCom.toTxPool(txList, ntNextFee, noisy = noisy)
      block:
        let
          pending = xq.nItems.pending
          staged = xq.nItems.staged
          packed = xq.nItems.packed

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

          # having the same set of txs, setting the xq database to the same
          # base fee as the xr one, the bucket fills of both database must
          # be the same after re-org
          xq.baseFee = ntNextFee
          xq.triggerReorg

          # now, xq should look like xr
          check xq.verify.isOK
          check xq.nItems == xr.nItems

      block:
        # get some value below the middle
        let
          packPrice = ((minGasPrice + maxGasPrice).uint64 div 3).GasPrice
          lowerPrice = minGasPrice + 1.GasPrice

        test &"Packing txs, baseFee=0 minPrice={packPrice} "&
            &"targetBlockSize={xq.trgGasLimit}":

          # verify that the test does not degenerate
          check 0 < minGasPrice
          check minGasPrice < maxGasPrice

          # ignore base limit so that the `packPrice` below becomes effective
          xq.baseFee = 0.GasPrice
          check xq.nItems.disposed == 0

          # set minimum target price
          xq.minPreLondonGasPrice = packPrice
          check xq.minPreLondonGasPrice == packPrice

          # employ packer
          # xq.jobCommit(forceMaintenance = true)
          xq.packerVmExec
          check xq.verify.isOK

          # verify that the test did not degenerate
          check 0 < xq.gasTotals.packed
          check xq.nItems.disposed == 0

          # assemble block from `packed` bucket
          let
            items = xq.toItems(txItemPacked)
            total = foldl(@[0.GasInt] & items.mapIt(it.tx.gasLimit), a+b)
          check xq.gasTotals.packed == total

          noisy.say "***", "1st bLock size=", total, " stats=", xq.nItems.pp

        test &"Clear and re-pack bucket":
          # prepare for POS transition in txpool
          xq.chain.com.pos.timestamp = getTime()

          let
            items0 = xq.toItems(txItemPacked)
            saveState0 = foldl(@[0.GasInt] & items0.mapIt(it.tx.gasLimit), a+b)
          check 0 < xq.nItems.packed

          # re-pack bucket
          #xq.jobCommit(forceMaintenance = true)
          xq.packerVmExec
          check xq.verify.isOK

          let
            items1 = xq.toItems(txItemPacked)
            saveState1 = foldl(@[0.GasInt] & items1.mapIt(it.tx.gasLimit), a+b)
          check items0 == items1
          check saveState0 == saveState1

        test &"Delete item and re-pack bucket/w lower minPrice={lowerPrice}":
          # verify that the test does not degenerate
          check 0 < lowerPrice
          check lowerPrice < packPrice
          check 0 < xq.nItems.packed

          let
            saveStats = xq.nItems
            lastItem = xq.toItems(txItemPacked)[^1]

          # delete last item from packed bucket
          xq.disposeItems(lastItem)
          check xq.verify.isOK

          # set new minimum target price
          xq.minPreLondonGasPrice = lowerPrice
          check xq.minPreLondonGasPrice == lowerPrice

          # re-pack bucket, packer needs extra trigger because there is
          # not necessarily a buckets re-org resulting in a change
          #xq.jobCommit(forceMaintenance = true)
          xq.packerVmExec
          check xq.verify.isOK

          let
            items = xq.toItems(txItemPacked)
            newTotal = foldl(@[0.GasInt] & items.mapIt(it.tx.gasLimit), a+b)
            newStats = xq.nItems
            newItem = xq.toItems(txItemPacked)[^1]

          # for sanity assert the obvoius
          check 0 < xq.gasTotals.packed
          check xq.gasTotals.packed == newTotal

          # verify incremental packing
          check lastItem.info != newItem.info
          check saveStats.packed >= newStats.packed

          noisy.say "***", "2st bLock size=", newTotal, " stats=", newStats.pp

    # -------------------------------------------------

    block:
      var
        xq = bcCom.toTxPool(txList, ntBaseFee,
                           local = localAccounts,
                           noisy = noisy)
      let
        (nMinTxs, nTrgTxs) = (15, 15)
        (nMinAccounts, nTrgAccounts) = (1, 8)
        canonicalHead = xq.chain.com.db.getCanonicalHead

      test &"Back track block chain head (at least "&
          &"{nMinTxs} txs, {nMinAccounts} known accounts)":

        # get the environment of a state back in the block chain, preferably
        # at least `nTrgTxs` txs and `nTrgAccounts` known accounts
        let
          (backHeader,backTxs,accLst) = xq.getBackHeader(nTrgTxs,nTrgAccounts)
          nBackBlocks = xq.head.blockNumber - backHeader.blockNumber
          stats = xq.nItems

        # verify that the test would not degenerate
        check nMinAccounts <= accLst.len
        check nMinTxs <= backTxs.len

        noisy.say "***",
          &"back tracked block chain:" &
          &" {backTxs.len} txs, {nBackBlocks} blocks," &
          &" {accLst.len} known accounts"

        check xq.smartHead(backHeader) # move insertion point

        # make sure that all txs have been added to the pool
        check stats.disposed == 0
        check stats.total + backTxs.len == xq.nItems.total

      test &"Run packer, profitability will not increase with block size":

        xq.flags = xq.flags - {packItemsMaxGasLimit}
        xq.packerVmExec
        let
          smallerBlockProfitability = xq.profitability
          smallerBlockSize = xq.gasCumulative

        noisy.say "***", "trg-packing",
          " profitability=", xq.profitability,
          " used=", xq.gasCumulative,
          " trg=", xq.trgGasLimit,
          " slack=", xq.trgGasLimit - xq.gasCumulative

        xq.flags = xq.flags + {packItemsMaxGasLimit}
        xq.packerVmExec

        noisy.say "***", "max-packing",
          " profitability=", xq.profitability,
          " used=", xq.gasCumulative,
          " max=", xq.maxGasLimit,
          " slack=", xq.maxGasLimit - xq.gasCumulative

        check smallerBlockSize <= xq.gasCumulative
        check 0 < xq.profitability

        # Well, this ratio should be above 100 but might be slightly less
        # with small data samples (pathological case.)
        let blockProfitRatio =
          (((smallerBlockProfitability.uint64 * 1000) div
            (max(1u64,xq.profitability.uint64))) + 5) div 10
        check decreasingBlockProfitRatioPC <= blockProfitRatio

        noisy.say "***", "cmp",
          " increase=", xq.gasCumulative - smallerBlockSize,
          " trg/max=", blockProfitRatio, "%"

      # if true: return
      test "Store generated block in block chain database":

        # authorized signer is needed to produce correct
        # POA difficulty and blockheader fields
        bcCom.poa.authorize(testAddress, signerFunc)

        noisy.say "***", "locality",
          " locals=", xq.accountRanks.local.len,
          " remotes=", xq.accountRanks.remote.len

        # Force maximal block size. Accidentally, the latest tx should have
        # a `gasLimit` exceeding the available space on the block `gasLimit`
        # which will be checked below.
        xq.flags = xq.flags #+ {packItemsMaxGasLimit}

        # Invoke packer
        let blk = xq.ethBlock

        # Make sure that there are at least two txs on the packed block so
        # this test does not degenerate.
        check 1 < xq.chain.receipts.len

        var overlap = -1
        for n in countDown(blk.txs.len - 1, 0):
          let total = xq.chain.receipts[n].cumulativeGasUsed
          if blk.header.gasUsed < total + blk.txs[n].gasLimit:
            overlap = n
            break

        noisy.say "***",
          "overlap=#", overlap,
          " tx=#", blk.txs.len,
          " gasUsed=", blk.header.gasUsed,
          " gasLimit=", blk.header.gasLimit

        if 0 <= overlap:
          let
            n = overlap
            mostlySize = xq.chain.receipts[n].cumulativeGasUsed
          noisy.say "***", "overlap",
            " size=", mostlySize + blk.txs[n].gasLimit - blk.header.gasUsed

        let
          poa = bcCom.poa
          bdy = BlockBody(transactions: blk.txs, withdrawals: blk.withdrawals)
          hdr = block:
            var rc = blk.header
            rc.gasLimit = blk.header.gasLimit
            rc.testKeySign

        # Make certain that some tx was set up so that its gasLimit overlaps
        # with the total block size. Of course, running it in the VM will burn
        # much less than permitted so this block will be accepted.
        check 0 < overlap

        setTraceLevel()

        # Test low-level function for adding the new block to the database
        #xq.chain.maxMode = (packItemsMaxGasLimit in xq.flags)
        xq.chain.clearAccounts
        check xq.chain.vmState.processBlock(poa, hdr, bdy).isOK

        setErrorLevel()

        # Re-allocate using VM environment from `persistBlocks()`
        let vmstate2 = BaseVMState.new(hdr, bcCom)
        check vmstate2.processBlock(poa, hdr, bdy).isOK

        # This should not have changed
        check canonicalHead == xq.chain.com.db.getCanonicalHead

        # Using the high-level library function, re-append the block while
        # turning off header verification.
        let c = bcCom.newChain(extraValidation = false)

        check c.persistBlocks(@[hdr], @[bdy]).isOK

        if bcCom.consensus == ConsensusType.POS:
          # PoS consensus will force the new blockheader as head
          # even though the difficulty or the blocknumber is lower than
          # previous canonical head
          check hdr.blockHash == xq.chain.com.db.getCanonicalHead.blockHash

          # Is the withdrawals persisted and loaded properly?
          var blockBody: BlockBody
          check xq.chain.com.db.getBlockBody(hdr, blockBody)
          check bdy == blockBody
        else:
          # The canonical head will be set to hdr if it scores high enough
          # (see implementation of db_chain.persistHeaderToDb()).
          let
            canonScore = xq.chain.com.db.getScore(canonicalHead.blockHash)
            headerScore = xq.chain.com.db.getScore(hdr.blockHash)

          if canonScore < headerScore:
            # Note that the updated canonical head is equivalent to hdr but not
            # necessarily binary equal.
            check hdr.blockHash == xq.chain.com.db.getCanonicalHead.blockHash
          else:
            check canonicalHead == xq.chain.com.db.getCanonicalHead

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc txPoolMain*(noisy = defined(debug)) =
  noisy.runTxLoader
  noisy.runTxPoolTests
  noisy.runTxPackerTests
  runTxPoolCliqueTest()
  runTxPoolPosTest()
  runTxPoolBlobhashTest()
  noisy.runTxHeadDelta

when isMainModule:
  const
    noisy = defined(debug)
    capts0: CaptureSpecs = goerliCapture
    capts1: CaptureSpecs = (GoerliNet, "goerli482304.txt.gz", 30000, 500, 1500)
    # Note: mainnet has the leading 45k blocks without any transactions
    capts2: CaptureSpecs = (MainNet, "mainnet332160.txt.gz", 30000, 500, 1500)

  setErrorLevel()

  noisy.runTxLoader(capture = capts1)
  noisy.runTxPoolTests
  noisy.runTxPackerTests

  runTxPoolCliqueTest()
  runTxPoolPosTest()
  runTxPoolBlobhashTest()
  noisy.runTxHeadDelta

  #noisy.runTxLoader(dir = ".")
  #noisy.runTxPoolTests

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
