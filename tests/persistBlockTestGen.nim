# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  json, stint,
  results,
  ../nimbus/[tracer, config],
  ../nimbus/core/chain,
  ../nimbus/common/common,
  ../nimbus/db/opts,
  ../nimbus/db/core_db/persistent

proc dumpTest(com: CommonRef, blockNumber: int) =
  let
    blockNumber = blockNumber.u256
    parentNumber = blockNumber - 1

  var
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)

  let
    parent = captureCom.db.getBlockHeader(parentNumber)
    blk = captureCom.db.getEthBlock(blockNumber)
    chain = newChain(captureCom)

  discard captureCom.db.setHead(parent, true)
  discard chain.persistBlocks([blk])

  var metaData = %{
    "blockNumber": %blockNumber.toHex
  }

  metaData.dumpMemoryDB(capture)
  writeFile("block" & $blockNumber & ".json", metaData.pretty())

proc main() {.used.} =
  # 97 block with uncles
  # 46147 block with first transaction
  # 46400 block with transaction
  # 46402 block with first contract: failed
  # 47205 block with first success contract
  # 48712 block with 5 transactions
  # 48915 block with contract
  # 49018 first problematic block
  # 52029 first block with receipts logs
  # 66407 failed transaction

  # nimbus --rpcapi: eth, debug --prune: archive

  var conf = makeConfig()
  let db = newCoreDbRef(
    DefaultDbPersistent, string conf.dataDir, DbOptions.init())
  let com = CommonRef.new(db)

  com.dumpTest(97)
  com.dumpTest(98) # no uncles and no tx
  com.dumpTest(46147)
  com.dumpTest(46400)
  com.dumpTest(46402)
  com.dumpTest(47205)
  com.dumpTest(48712)
  com.dumpTest(48915)
  com.dumpTest(49018)
  com.dumpTest(49439) # call opcode bug
  com.dumpTest(49891) # number opcode bug
  com.dumpTest(50111) # apply message bug
  com.dumpTest(78458 )
  com.dumpTest(81383 ) # tracer gas cost, stop opcode
  com.dumpTest(81666 ) # create opcode
  com.dumpTest(85858 ) # call oog
  com.dumpTest(116524) # codecall address
  com.dumpTest(146675) # precompiled contracts ecRecover
  com.dumpTest(196647) # not enough gas to call
  com.dumpTest(226147) # create return gas
  com.dumpTest(226522) # return
  com.dumpTest(231501) # selfdestruct
  com.dumpTest(243826) # create contract self destruct
  com.dumpTest(248032) # signextend over/undeflow
  com.dumpTest(299804) # GasInt overflow
  com.dumpTest(420301) # computation gas cost LTE(<=) 0 to LT(<) 0
  com.dumpTest(512335) # create apply message
  com.dumpTest(47216)   # regression
  com.dumpTest(652148)  # contract transfer bug
  com.dumpTest(668910)  # uncleared logs bug
  com.dumpTest(1_017_395) # sha256 and ripemd precompiles wordcount bug
  com.dumpTest(1_149_150) # need to swallow precompiles errors
  com.dumpTest(1_155_095) # homestead codeCost OOG
  com.dumpTest(1_317_742) # CREATE childmsg sender
  com.dumpTest(1_352_922) # first ecrecover precompile with 0x0 input
  com.dumpTest(1_368_834) # writepadded regression padding len
  com.dumpTest(1_417_555) # writepadded regression zero len
  com.dumpTest(1_431_916) # deep recursion stack overflow problem
  com.dumpTest(1_487_668) # getScore uint64 vs uint256 overflow
  com.dumpTest(1_920_000) # the DAO fork
  com.dumpTest(1_927_662) # fork comparison bug in postExecuteVM

  # too big and too slow, we can skip it
  # because it already covered by GST
  #chainDB.dumpTest(2_283_416) # first DDOS spam attack block
  com.dumpTest(2_463_413) # tangerine call* gas cost bug
  com.dumpTest(2_675_000) # spurious dragon first block
  com.dumpTest(2_675_002) # EIP155 tx.getSender
  com.dumpTest(4_370_000) # Byzantium first block

when isMainModule:
  try:
    main()
  except:
    echo getCurrentExceptionMsg()
