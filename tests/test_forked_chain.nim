# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  pkg/chronicles,
  pkg/unittest2,
  ../nimbus/common,
  ../nimbus/config,
  ../nimbus/utils/utils,
  ../nimbus/core/chain/forked_chain,
  ../nimbus/db/ledger,
  ./test_forked_chain/chain_debug

const
  genesisFile = "tests/customgenesis/cancun123.json"
  senderAddr  = address"73cf19657412508833f618a15e8251306b3e6ee5"

type
  TestEnv = object
    conf: NimbusConf

proc setupEnv(): TestEnv =
  let
    conf = makeConfig(@[
      "--custom-network:" & genesisFile
    ])

  TestEnv(conf: conf)

proc newCom(env: TestEnv): CommonRef =
  CommonRef.new(
      newCoreDbRef DefaultDbMemory,
      nil,
      env.conf.networkId,
      env.conf.networkParams
    )

proc makeBlk(txFrame: CoreDbTxRef, number: BlockNumber, parentBlk: Block): Block =
  template parent(): Header =
    parentBlk.header

  var wds = newSeqOfCap[Withdrawal](number.int)
  for i in 0..<number:
    wds.add Withdrawal(
      index: i,
      validatorIndex: 1,
      address: senderAddr,
      amount: 1,
    )

  let ledger = LedgerRef.init(txFrame)
  for wd in wds:
    ledger.addBalance(wd.address, wd.weiAmount)

  ledger.persist()

  let wdRoot = calcWithdrawalsRoot(wds)
  var body = BlockBody(
    withdrawals: Opt.some(move(wds))
  )

  let header = Header(
    number     : number,
    parentHash : parent.blockHash,
    difficulty : 0.u256,
    timestamp  : parent.timestamp + 1,
    gasLimit   : parent.gasLimit,
    stateRoot  : ledger.getStateRoot(),
    transactionsRoot     : parent.txRoot,
    baseFeePerGas  : parent.baseFeePerGas,
    receiptsRoot   : parent.receiptsRoot,
    ommersHash     : parent.ommersHash,
    withdrawalsRoot: Opt.some(wdRoot),
    blobGasUsed    : parent.blobGasUsed,
    excessBlobGas  : parent.excessBlobGas,
    parentBeaconBlockRoot: parent.parentBeaconBlockRoot,
  )

  Block.init(header, body)

proc makeBlk(txFrame: CoreDbTxRef, number: BlockNumber, parentBlk: Block, extraData: byte): Block =
  var blk = txFrame.makeBlk(number, parentBlk)
  blk.header.extraData = @[extraData]
  blk

proc headHash(c: ForkedChainRef): Hash32 =
  c.latestTxFrame.getCanonicalHead().expect("canonical head exists").blockHash

func blockHash(x: Block): Hash32 =
  x.header.blockHash

proc wdWritten(c: ForkedChainRef, blk: Block): int =
  if blk.header.withdrawalsRoot.isSome:
    c.latestTxFrame.getWithdrawals(blk.header.withdrawalsRoot.get).
      expect("withdrawals exists").len
  else:
    0

template checkImportBlock(chain, blk) =
  let res = chain.importBlock(blk)
  check res.isOk
  if res.isErr:
    debugEcho "IMPORT BLOCK FAIL: ", res.error
    debugEcho "Block Number: ", blk.header.number

template checkImportBlockErr(chain, blk) =
  let res = chain.importBlock(blk)
  check res.isErr
  if res.isOk:
    debugEcho "IMPORT BLOCK SHOULD FAIL"
    debugEcho "Block Number: ", blk.header.number

template checkForkChoice(chain, a, b) =
  let res = chain.forkChoice(a.blockHash, b.blockHash)
  check res.isOk
  if res.isErr:
    debugEcho "FORK CHOICE FAIL: ", res.error
    debugEcho "Block Number: ", a.header.number, " ", b.header.number

template checkForkChoiceErr(chain, a, b) =
  let res = chain.forkChoice(a.blockHash, b.blockHash)
  check res.isErr
  if res.isOk:
    debugEcho "FORK CHOICE SHOULD FAIL"
    debugEcho "Block Number: ", a.header.number, " ", b.header.number

template checkPersisted(chain, blk) =
  let res = chain.baseTxFrame.getBlockHeader(blk.blockHash)
  check res.isOk
  if res.isErr:
    debugEcho "CHECK FINALIZED FAIL: ", res.error
    debugEcho "Block Number: ", blk.header.number

proc forkedChainMain*() =
   suite "ForkedChainRef tests":
     var env = setupEnv()
     let
       cc = env.newCom
       genesisHash = cc.genesisHeader.blockHash
       genesis = Block.init(cc.genesisHeader, BlockBody())
       baseTxFrame = cc.db.baseTxFrame()

     let
       blk1 = baseTxFrame.makeBlk(1, genesis)
       blk2 = baseTxFrame.makeBlk(2, blk1)
       blk3 = baseTxFrame.makeBlk(3, blk2)

       dbTx = baseTxFrame.txFrameBegin
       blk4 = dbTx.makeBlk(4, blk3)
       blk5 = dbTx.makeBlk(5, blk4)
       blk6 = dbTx.makeBlk(6, blk5)
       blk7 = dbTx.makeBlk(7, blk6)

     dbTx.dispose()

     let
       B4 = baseTxFrame.makeBlk(4, blk3, 1.byte)
       B5 = baseTxFrame.makeBlk(5, B4)
       B6 = baseTxFrame.makeBlk(6, B5)
       B7 = baseTxFrame.makeBlk(7, B6)

     test "newBase == oldBase":
       const info = "newBase == oldBase"
       let com = env.newCom()

       var chain = ForkedChainRef.init(com)

       # same header twice
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk1)

       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       check chain.validate info & " (1)"

       # no parent
       checkImportBlockErr(chain, blk5)

       check chain.headHash == genesisHash
       check chain.latestHash == blk3.blockHash
       check chain.validate info & " (2)"

       # finalized > head -> error
       checkForkChoiceErr(chain, blk1, blk3)
       check chain.validate info & " (3)"

       # blk4 is not part of chain
       checkForkChoiceErr(chain, blk4, blk2)

       # finalized > head -> error
       checkForkChoiceErr(chain, blk1, blk2)

       # blk4 is not part of chain
       checkForkChoiceErr(chain, blk2, blk4)

       # finalized < head -> ok
       checkForkChoice(chain, blk2, blk1)
       check chain.headHash == blk2.blockHash
       check chain.latestHash == blk2.blockHash
       check chain.validate info & " (7)"

       # finalized == head -> ok
       checkForkChoice(chain, blk2, blk2)
       check chain.headHash == blk2.blockHash
       check chain.latestHash == blk2.blockHash
       check chain.baseNumber == 0'u64
       check chain.validate info & " (8)"

       # baggage written
       check chain.wdWritten(blk1) == 1
       check chain.wdWritten(blk2) == 2
       check chain.validate info & " (9)"

     test "newBase on activeBranch":
       const info = "newBase on activeBranch"
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 3)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, blk4)
       check chain.validate info & " (1)"

       # newbase == head
       checkForkChoice(chain, blk7, blk6)
       check chain.validate info & " (2)"

       check chain.headHash == blk7.blockHash
       check chain.latestHash == blk7.blockHash
       check chain.baseBranch == chain.activeBranch

       check chain.wdWritten(blk7) == 7

       # head - baseDistance must been persisted
       checkPersisted(chain, blk3)

       # make sure aristo not wiped out baggage
       check chain.wdWritten(blk3) == 3
       check chain.validate info & " (9)"

     test "newBase between oldBase and head":
       const info = "newBase between oldBase and head"
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 3)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)
       check chain.validate info & " (1)"

       checkForkChoice(chain, blk7, blk6)
       check chain.validate info & " (2)"

       check chain.headHash == blk7.blockHash
       check chain.latestHash == blk7.blockHash
       check chain.baseBranch == chain.activeBranch

       check chain.wdWritten(blk6) == 6
       check chain.wdWritten(blk7) == 7

       # head - baseDistance must been persisted
       checkPersisted(chain, blk3)

       # make sure aristo not wiped out baggage
       check chain.wdWritten(blk3) == 3
       check chain.validate info & " (9)"

     test "newBase == oldBase, fork and stay on that fork":
       const info = "newBase == oldBase, fork .."
       let com = env.newCom()

       var chain = ForkedChainRef.init(com)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)
       check chain.validate info & " (1)"

       checkForkChoice(chain, B7, B5)

       check chain.headHash == B7.blockHash
       check chain.latestHash == B7.blockHash
       check chain.baseNumber == 0'u64
       check chain.branches.len == 2

       check chain.validate info & " (9)"

     test "newBase move forward, fork and stay on that fork":
       const info = "newBase move forward, fork .."
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 3)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)

       checkImportBlock(chain, B4)
       check chain.validate info & " (1)"

       checkForkChoice(chain, B6, B4)
       check chain.validate info & " (2)"

       check chain.headHash == B6.blockHash
       check chain.latestHash == B6.blockHash
       check chain.baseNumber == 3'u64
       check chain.branches.len == 2
       check chain.validate info & " (9)"

     test "newBase on shorter canonical arc, remove oldBase branches":
       const info = "newBase on shorter canonical, remove oldBase branches"
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 3)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)
       check chain.validate info & " (1)"

       checkForkChoice(chain, B7, B6)
       check chain.validate info & " (2)"

       check chain.headHash == B7.blockHash
       check chain.latestHash == B7.blockHash
       check chain.baseNumber == 4'u64
       check chain.branches.len == 1
       check chain.validate info & " (9)"

     test "newBase on curbed non-canonical arc":
       const info = "newBase on curbed non-canonical .."
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 5)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)
       check chain.validate info & " (1)"

       checkForkChoice(chain, B7, B5)
       check chain.validate info & " (2)"

       check chain.headHash == B7.blockHash
       check chain.latestHash == B7.blockHash
       check chain.baseNumber > 0
       check chain.baseNumber < B4.header.number
       check chain.branches.len == 2
       check chain.validate info & " (9)"

     test "newBase == oldBase, fork and return to old chain":
       const info = "newBase == oldBase, fork .."
       let com = env.newCom()

       var chain = ForkedChainRef.init(com)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)
       check chain.validate info & " (1)"

       checkForkChoice(chain, blk7, blk5)
       check chain.validate info & " (2)"

       check chain.headHash == blk7.blockHash
       check chain.latestHash == blk7.blockHash
       check chain.baseNumber == 0'u64
       check chain.validate info & " (9)"

     test "newBase on activeBranch, fork and return to old chain":
       const info = "newBase on activeBranch, fork .."
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 3)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)

       checkImportBlock(chain, blk4)
       check chain.validate info & " (1)"

       checkForkChoice(chain, blk7, blk5)
       check chain.validate info & " (2)"

       check chain.headHash == blk7.blockHash
       check chain.latestHash == blk7.blockHash
       check chain.baseBranch == chain.activeBranch
       check chain.validate info & " (9)"

     test "newBase on shorter canonical arc, discard arc with oldBase" &
          " (ign dup block)":
       const info = "newBase on shorter canonical .."
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 3)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)

       checkImportBlock(chain, blk4)
       check chain.validate info & " (1)"

       checkForkChoice(chain, B7, B5)
       check chain.validate info & " (2)"

       check chain.headHash == B7.blockHash
       check chain.latestHash == B7.blockHash
       check chain.baseNumber == 4'u64
       check chain.branches.len == 1
       check chain.validate info & " (9)"

     test "newBase on longer canonical arc, discard new branch":
       const info = "newBase on longer canonical .."
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 3)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)
       check chain.validate info & " (1)"

       checkForkChoice(chain, blk7, blk5)
       check chain.validate info & " (2)"

       check chain.headHash == blk7.blockHash
       check chain.latestHash == blk7.blockHash
       check chain.baseNumber > 0
       check chain.baseNumber < blk5.header.number
       check chain.branches.len == 1
       check chain.validate info & " (9)"

     test "headerByNumber":
       const info = "headerByNumber"
       let com = env.newCom()

       var chain = ForkedChainRef.init(com, baseDistance = 3)
       checkImportBlock(chain, blk1)
       checkImportBlock(chain, blk2)
       checkImportBlock(chain, blk3)
       checkImportBlock(chain, blk4)
       checkImportBlock(chain, blk5)
       checkImportBlock(chain, blk6)
       checkImportBlock(chain, blk7)

       checkImportBlock(chain, B4)
       checkImportBlock(chain, B5)
       checkImportBlock(chain, B6)
       checkImportBlock(chain, B7)
       check chain.validate info & " (1)"

       checkForkChoice(chain, blk7, blk5)
       check chain.validate info & " (2)"

       # cursor
       check chain.headerByNumber(8).isErr
       check chain.headerByNumber(7).expect("OK").number == 7
       check chain.headerByNumber(7).expect("OK").blockHash == blk7.blockHash

       # from db
       check chain.headerByNumber(3).expect("OK").number == 3
       check chain.headerByNumber(3).expect("OK").blockHash == blk3.blockHash

       # base
       check chain.headerByNumber(4).expect("OK").number == 4
       check chain.headerByNumber(4).expect("OK").blockHash == blk4.blockHash

       # from cache
       check chain.headerByNumber(5).expect("OK").number == 5
       check chain.headerByNumber(5).expect("OK").blockHash == blk5.blockHash
       check chain.validate info & " (9)"


when isMainModule:
  forkedChainMain()
