# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[algorithm, sets],
  pkg/eth/common,
  pkg/[results, unittest2],
  ../../nimbus/common,
  ../../nimbus/core/chain,
  ../../nimbus/db/[core_db, edge_db, era1_db],
  ./test_helpers

const
  NotFound = Result[Blob,EdgeDbError].err(EdgeKeyNotFound)

# ------------------------------------------------------------------------------
# Test runner
# ------------------------------------------------------------------------------

proc testEra1CoreDbMain*() =
  suite "EdgeDb test Era1Db vs CoreDb":
    let
      e1db = newEra1DbInstance()
      blockNumbers = e1db.randomBlockNumbers(24, 12345)

    test "Find existing blocks":
      let
        cdb = newCoreDbInstance()
        edb = EdgeDbRef.init(e1db, cdb)
      for bn in blockNumbers:
        let
          blkData = edb.get(EthBlockData, bn).expect "valid block data"
          hdrData = edb.get(EthHeaderData, bn).expect "valid header data"
          bdyData = edb.get(EthBodyData, bn).expect "valid body data"
          e1Blk = e1db.getEthBlock(bn).expect "valid eth block"
          e1Tpl = e1db.getBlockTuple(bn).expect "valid block tuple"
        check blkData == rlp.encode(e1Blk)
        check hdrData == rlp.encode(e1Tpl.header)
        check bdyData == rlp.encode(e1Tpl.body)

    test "Fail finding missing blocks":
      let
        cdb = newCoreDbInstance()
        edb = EdgeDbRef.init(e1db, blockNumbers.toHashSet, cdb)
      for bn in blockNumbers:
        check edb.get(EthBlockData, bn) == NotFound
        check edb.get(EthHeaderData, bn) == NotFound
        check edb.get(EthBodyData, bn) == NotFound

    test "Find existing blocks in CoreDb":
      when not defined(release):
        setErrorLevel() # reduce logging for on-the-fly testing
      let
        com = newCommonInstance()
        edb = EdgeDbRef.init(e1db, blockNumbers.toHashSet, com.db)

      # Import relevant blocks into CoreDb
      let
        maxBlk = blockNumbers.sorted[^1]
        chunk = 1024
        chain = com.newChain()
      for n in 1u64.countUp(maxBlk, chunk):
        let blks = e1db.getBlockList(n, min(n + chunk.uint - 1, maxBlk))
        discard chain.persistBlocks(blks).expect "working import"

      for bn in blockNumbers:
        let
          blkData = edb.get(EthBlockData, bn).expect "valid block data"
          hdrData = edb.get(EthHeaderData, bn).expect "valid header data"
          bdyData = edb.get(EthBodyData, bn).expect "valid body data"
          e1Blk = e1db.getEthBlock(bn).expect "valid eth block"
          e1Tpl = e1db.getBlockTuple(bn).expect "valid block tuple"
        check blkData == rlp.encode(e1Blk)
        check hdrData == rlp.encode(e1Tpl.header)
        check bdyData == rlp.encode(e1Tpl.body)

when isMainModule:
  testEra1CoreDbMain()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
