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
  std/[algorithm, os, sequtils, strformat, strutils, times],
  ../nimbus/utils/tx_pool,
  ./test_txpool/helpers,
  eth/[common, keys],
  stint,
  unittest2

const
  goerliCapture = "test_clique" / "goerli51840.txt.gz"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

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
        let info = &"{count} #{blkNum}({chainNo}) {n}/{txs.len}"
        noisy.showElapsed(&"insert: {info}"):
          doAssert xp.insert(tx = txs[n], info = info).isOk
        if stopAfter <= count:
          return
    chainNo.inc


proc toTxPool(q: var seq[TxItemRef]; noisy = true): TxPool =
  result.init
  noisy.showElapsed(&"Loading {q.len} transactions"):
    for w in q:
      doAssert result.insert(tx = w.tx, info = w.info).value == w.id
  doAssert result.len == q.len


proc addOrFlushGroupwise(xp: var TxPool;
                         grpLen: int; seen: var seq[Hash256]; n: Hash256;
                         noisy = true) =
  seen.add n
  if seen.len < grpLen:
    return

  # flush group-wise
  let xpLen = xp.len
  if noisy:
    echo "*** updateSeen: deleting ", seen.mapIt($it).join(" ")
  for a in seen:
    doAssert xp.delete(a).value.id == a
  doAssert xpLen == seen.len + xp.len
  seen.setLen(0)

# ------------------------------------------------------------------------------
# Test Runner
# ------------------------------------------------------------------------------

proc runTxStepper(noisy = true;
                  dir = "tests"; captureFile = goerliCapture,
                  numTransactions = 0) =

  let
    elapNoisy = false
    stopAfter = if numTransactions == 0: 500 else: numTransactions
  var
    txList: seq[TxItemRef]
    gasPrices: seq[GasInt]

  suite &"TxPool: Collect {stopAfter} transactions from Goerli capture":

    test &"Transactions collected":
      var xp = initTxPool()
      noisy.showElapsed("Total Collection Time"):
        xp.collectTxPool(elapNoisy, dir / captureFile, stopAfter)

      # Note: expecting enough transactions in the `goerliCapture` file
      check xp.len == stopAfter
      check xp.verify.isOk

      # Load txList[]
      for w in xp.firstOutItems:
        txList.add w
      check txList.len == xp.len

    # ---------------------------------

    block:
      var xq = txList.toTxPool(noisy)
      let veryNoisy = noisy and false

      test &"Walk {xq.byGasPriceLen} gas prices for {txList.len} transactions":
        block:
          var
            txCount = 0
            gpList: seq[GasInt]

          noisy.showElapsed("Increasing gas price walk on transactions"):
            for (gasPrice,itemsLst) in xq.byGasPriceIncPairs:
              var infoList: seq[string]
              for w in itemsLst.nextKeys: # prevKeys() also works
                infoList.add w.info
              gpList.add gasPrice
              txCount += itemsLst.len
              if veryNoisy:
                echo &">>> gasPrice={gasPrice} for {infoList.len} entries:"
                let indent = " ".repeat(6)
                echo indent, infoList.join(&"\n{indent}")

          check txCount == xq.len
          check gpList.len == xq.byGasPriceLen
          gasPrices = gpList

        block:
          var
            gpCount = 0
            txCount = 0
            gpList: seq[GasInt]

          noisy.showElapsed("Decreasing gas price walk on transactions"):
            for (gasPrice,itemsLst) in xq.byGasPriceDecPairs:
              var infoList: seq[string]
              for w in itemsLst.prevKeys: # nextKeys() also works
                infoList.add w.info
              gpList.add gasPrice
              txCount += itemsLst.len
              if veryNoisy:
                echo &">>> gasPrice={gasPrice} for {infoList.len} entries:"
                let indent = " ".repeat(6)
                echo indent, infoList.join(&"\n{indent}")

          check txCount == xq.len
          check gpList.len == xq.byGasPriceLen
          check gasPrices == gpList.reversed

      test "Walk transaction ID queue fwd/rev":
        block:
          var top = 0
          for w in xq.firstOutItems:
            check txList[top].id == w.id
            top.inc
          check top == txList.len
        block:
          var top = txList.len
          for w in xq.lastInItems:
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
        noisy.showElapsed("Forward delete-walk ID queue"):
          for w in xq.firstOutItems:
            xq.addOrFlushGroupwise(groupLen, seen, w.id, veryNoisy)
            check xq.verify.isOK
        check seen.len == xq.len
        check seen.len < groupLen

      test &"Load/reverse walk ID queue, " &
          &"deleting in groups of at most {groupLen}":
        var
          xq = txList.toTxPool(noisy)
          seen: seq[Hash256]
        check xq.verify.isOK
        noisy.showElapsed("Revese delete-walk ID queue"):
          for w in xq.lastInItems:
            xq.addOrFlushGroupwise(groupLen, seen, w.id, veryNoisy)
            check xq.verify.isOK
        check seen.len == xq.len
        check seen.len < groupLen

    # ---------------------------------

    block:
      var
        xq = txList.toTxPool(noisy)
        count = 0
      let
        delLe = gasPrices[0] + ((gasPrices[^1] - gasPrices[0]) div 3)
        delMax = block:
          var itLst = xq.byGasPriceLe(delLe).value
          itLst.firstKey.value.tx.gasPrice

      test &"Load/delete with gas price less equal {delMax.toKMG}, " &
          &"out of price range {gasPrices[0].toKMG}..{gasPrices[^1].toKMG}":
        noisy.showElapsed(&"Deleting gas prices less equal {delMax.toKMG}"):
          for (gp,itemList) in xq.byGasPriceDecPairs(delMax):
            for item in itemList.nextKeys:
              count.inc
              check xq.delete(item).isOK
              check xq.verify.isOK
        check 0 < count
        check 0 < xq.len
        check count + xq.len == txList.len

    block:
      var
        xq = txList.toTxPool(noisy)
        count = 0
      let
        delGe = gasPrices[^1] - ((gasPrices[^1] - gasPrices[0]) div 3)
        delMin = block:
          var itLst = xq.byGasPriceGe(delGe).value
          itLst.firstKey.value.tx.gasPrice

      test &"Load/delete with gas price greater equal {delMin.toKMG}, " &
          &"out of price range {gasPrices[0].toKMG}..{gasPrices[^1].toKMG}":
        noisy.showElapsed(&"Deleting gas prices greater than {delMin.toKMG}"):
          for (gp,itemList) in xq.byGasPriceIncPairs(delMin):
            for item in itemList.nextKeys:
              count.inc
              check xq.delete(item).isOK
              check xq.verify.isOK
        check 0 < count
        check 0 < xq.len
        check count + xq.len == txList.len

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc txPoolMain*(noisy = defined(debug)) =
  noisy.runTxStepper

when isMainModule:
  let
    captFile1 = "nimbus-eth1" / "tests" / goerliCapture
    captFile2 = "goerli504192.txt.gz"

  let noisy = defined(debug)
  noisy.runTxStepper(dir = "/status", captureFile = captFile2,
                     numTransactions = 1500)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
