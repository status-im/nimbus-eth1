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
  std/[os, sequtils, strformat, strutils, times],
  ../nimbus/utils/tx_pool,
  ./test_clique/undump, # borrow from clique tools
  eth/[common, keys],
  stint,
  unittest2

const
  goerliCapture = "test_clique" / "goerli51840.txt.gz"

type
  TxWalK = tuple
    blockNumber: BlockNumber
    chainNo: int
    txCount: int
    txs: seq[Transaction]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc pp(txs: openArray[Transaction]; pfx = ""): string =
  let txt = block:
    var rc = ""
    if 0 < txs.len:
      rc = "[" & txs[0].pp
      for n in 1 ..< txs.len:
        rc &= ";" & txs[n].pp
      rc &= "]"
    rc
  txt.multiReplace([
    (",", &",\n   {pfx}"),
    (";", &",\n  {pfx}")])

proc pp(txs: openArray[Transaction]; pfxLen: int): string =
  txs.pp(" ".repeat(pfxLen))

proc ppMs(elapsed: Duration): string =
  result = $elapsed.inMilliSeconds
  let ns = elapsed.inNanoSeconds mod 1_000_000
  if ns != 0:
    # to rounded deca milli seconds
    let dm = (ns + 5_000i64) div 10_000i64
    result &= &".{dm:02}"
  result &= "ms"

proc ppSecs(elapsed: Duration): string =
  result = $elapsed.inSeconds
  let ns = elapsed.inNanoseconds mod 1_000_000_000
  if ns != 0:
    # to rounded decs seconds
    let ds = (ns + 5_000_000i64) div 10_000_000i64
    result &= &".{ds:02}"
  result &= "s"

template showElapsed(noisy: bool; info: string; code: untyped) =
  let start = getTime()
  code
  if noisy:
    let elpd {.inject.} = getTime() - start
    if 0 < elpd.inSeconds:
      echo "*** ", info, &": {elpd.ppSecs:>4}"
    else:
      echo "*** ", info, &": {elpd.ppMs:>4}"

# ------------------------------------------------------------------------------
# Test Runners
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

proc runTxStepper(noisy = true;
                  dir = "tests"; captureFile = goerliCapture,
                  numTransactions = 0) =

  let
    elapNoisy = false
    stopAfter = if numTransactions == 0: 500 else: numTransactions
  var
    xp = initTxPool()

  suite &"TxPool: Collect {stopAfter} transactions from Goerli capture":

    test &"Transactions collected":
      noisy.showElapsed("Total Collection Time"):
        xp.collectTxPool(elapNoisy, dir / captureFile, stopAfter)

      # Note: expecting enough transactions in the `goerliCapture` file
      check xp.len == stopAfter
      check xp.verify.isOk

    let
      numGasPrices = xp.byGasPriceLen

    test &"Walk {numGasPrices} gas prices for {xp.len} transactions":
      noisy.showElapsed("Gas price walk on collected transactions"):
        var
          gpCount = 0
          txCount = 0
        for (gasPrice,itemsLst) in xp.byGasPriceIncPairs:
          let infoList = toSeq(itemsLst.nextKeys).mapIt(it.info)
          gpCount.inc
          txCount += itemsLst.len
          if noisy and false:
            echo &">>> gasPrice={gasPrice} for {infoList.len} entries:"
            let indent = " ".repeat(6)
            echo indent, infoList.join(&"\n{indent}")
        check gpCount == numGasPrices
        check txCount == xp.len
        check xp.verify.isOK

    var txList: seq[(Hash256,string,Transaction)]

    test "Walk transaction ID queue fwd/rev":
      for w in xp.firstOutItems:
        txList.add (w.id, w.info, w.tx)
      check txList.len == xp.len

      var top = txList.len
      for w in xp.lastInItems:
        top.dec
        check txList[top][0] == w.id
        check txList[top][1] == w.info
        check txList[top][2].toKey == w.tx.toKey
      check top == 0
      check xp.verify.isOK

    const groupLen = 13

    proc fillTxList(xq: var TxPool) =
      for w in txList:
        doAssert xq.insert(w[2]).value == w[0]
      doAssert xq.len == txList.len

    proc updateSeen(xq: var TxPool; seen: var seq[Hash256]; n: Hash256) =
      seen.add n
      if groupLen <= seen.len:
        let xqLen = xq.len
        if noisy:
          # echo "*** updateSeen: deleting ", seen.mapIt($it).join(" ")
          discard
        for a in seen:
          doAssert xq.delete(a).value.id == a
        doAssert xqLen == seen.len + xq.len
        seen.setLen(0)

    test &"Load/forward walk ID queue, " &
           &"deleting groups of at most {groupLen}":
      var
        xq = initTxPool()
        seen: seq[Hash256]
      noisy.showElapsed(&"Loading {txList.len} transactions"):
        xq.fillTxList
      check xq.verify.isOK
      noisy.showElapsed("Forward delete-walk ID queue"):
        for w in xq.firstOutItems:
          xq.updateSeen(seen, w.id)
          check xq.verify.isOK
      check seen.len == xq.len
      check seen.len < groupLen

    test &"Load/reverse walk ID queue, " &
        &"deleting in groups of at most {groupLen}":
      var
        xq = initTxPool()
        seen: seq[Hash256]
      noisy.showElapsed(&"Loading {txList.len} transactions"):
        xq.fillTxList
      check xq.verify.isOK
      noisy.showElapsed("Revese delete-walk ID queue"):
        for w in xq.lastInItems:
          xq.updateSeen(seen, w.id)
          check xq.verify.isOK
      check seen.len == xq.len
      check seen.len < groupLen

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
