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
  pkg/chronos,
  pkg/unittest2,
  testutils,
  std/[os, strutils],
  ../execution_chain/common,
  ../execution_chain/config,
  ../execution_chain/utils/utils,
  ../execution_chain/core/chain/forked_chain,
  ../execution_chain/core/chain/forked_chain/chain_desc,
  ../execution_chain/core/chain/forked_chain/chain_serialize,
  ../execution_chain/core/chain/forked_chain/chain_branch,
  ../execution_chain/db/ledger,
  ../execution_chain/db/era1_db,
  ../execution_chain/db/fcu_db,
  ./test_forked_chain/chain_debug

const
  genesisFile = "tests/customgenesis/cancun123.json"
  senderAddr  = address"73cf19657412508833f618a15e8251306b3e6ee5"
  sourcePath  = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]

type
  TestEnv = object
    conf: NimbusConf

proc setupEnv(): TestEnv =
  let
    conf = makeConfig(@[
      "--network:" & genesisFile
    ])

  TestEnv(conf: conf)

proc newCom(env: TestEnv): CommonRef =
  CommonRef.new(
      newCoreDbRef DefaultDbMemory,
      nil,
      env.conf.networkId,
      env.conf.networkParams
    )

proc newCom(env: TestEnv, db: CoreDbRef): CommonRef =
  CommonRef.new(
      db,
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
    parentHash : parent.computeBlockHash,
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

template checkHeadHash(chain: ForkedChainRef, hashParam: Hash32) =
  let
    headHash = hashParam
    txFrame = chain.txFrame(headHash)
    res = txFrame.getCanonicalHeaderHash()

  check res.isOk
  if res.isErr:
    debugEcho "Canonical head hash should exists: ", res.error
  else:
    let canonicalHeadHash = res.get
    check headHash == canonicalHeadHash

  # also check if the header actually exists
  check txFrame.getCanonicalHead().isOk
  let rc = txFrame.fcuHead()
  check rc.isOk
  if rc.isErr:
    debugEcho "FCU HEAD: ", rc.error

func blockHash(x: Block): Hash32 =
  x.header.computeBlockHash

proc wdWritten(c: ForkedChainRef, blk: Block): int =
  if blk.header.withdrawalsRoot.isSome:
    let txFrame = c.txFrame(blk.blockHash)
    txFrame.getWithdrawals(blk.header.withdrawalsRoot.get).
      expect("withdrawals exists").len
  else:
    0

template checkImportBlock(chain, blk) =
  let res = waitFor chain.importBlock(blk)
  check res.isOk
  if res.isErr:
    debugEcho "IMPORT BLOCK FAIL: ", res.error
    debugEcho "Block Number: ", blk.header.number

template checkImportBlockErr(chain, blk) =
  let res = waitFor chain.importBlock(blk)
  check res.isErr
  if res.isOk:
    debugEcho "IMPORT BLOCK SHOULD FAIL"
    debugEcho "Block Number: ", blk.header.number

template checkForkChoice(chain, a, b) =
  let res = waitFor chain.forkChoice(a.blockHash, b.blockHash)
  check res.isOk
  if res.isErr:
    debugEcho "FORK CHOICE FAIL: ", res.error
    debugEcho "Block Number: ", a.header.number, " ", b.header.number

template checkForkChoiceErr(chain, a, b) =
  let res = waitFor chain.forkChoice(a.blockHash, b.blockHash)
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

suite "ForkedChainRef tests":
  var env = setupEnv()
  let
    cc = env.newCom
    genesisHash = cc.genesisHeader.computeBlockHash
    genesis = Block.init(cc.genesisHeader, BlockBody())
    baseTxFrame = cc.db.baseTxFrame()
    txFrame = baseTxFrame.txFrameBegin
  let
    blk1 = txFrame.makeBlk(1, genesis)
    blk2 = txFrame.makeBlk(2, blk1)
    blk3 = txFrame.makeBlk(3, blk2)
    dbTx = txFrame.txFrameBegin
    blk4 = dbTx.makeBlk(4, blk3)
    blk5 = dbTx.makeBlk(5, blk4)
    blk6 = dbTx.makeBlk(6, blk5)
    blk7 = dbTx.makeBlk(7, blk6)
    blk8 = dbTx.makeBlk(8, blk7)
  dbTx.dispose()
  let
    B4 = txFrame.makeBlk(4, blk3, 1.byte)
    dbTx2 = txFrame.txFrameBegin
    B5 = dbTx2.makeBlk(5, B4)
    B6 = dbTx2.makeBlk(6, B5)
    B7 = dbTx2.makeBlk(7, B6)
  dbTx2.dispose()
  let
    C5 = txFrame.makeBlk(5, blk4, 1.byte)
    C6 = txFrame.makeBlk(6, C5)
    C7 = txFrame.makeBlk(7, C6)
  txFrame.dispose()

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
    checkHeadHash chain, genesisHash
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
    checkHeadHash chain, blk2.blockHash
    check chain.latestHash == blk3.blockHash
    check chain.validate info & " (7)"
    # finalized == head -> ok
    checkForkChoice(chain, blk2, blk2)
    checkHeadHash chain, blk2.blockHash
    check chain.latestHash == blk3.blockHash
    check chain.baseNumber == 0'u64
    check chain.validate info & " (8)"
    # baggage written
    check chain.wdWritten(blk1) == 1
    check chain.wdWritten(blk2) == 2
    check chain.validate info & " (9)"

  test "newBase on activeBranch":
    const info = "newBase on activeBranch"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 0)
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
    checkHeadHash chain, blk7.blockHash
    check chain.latestHash == blk7.blockHash
    check chain.heads.len == 1
    check chain.wdWritten(blk7) == 7
    # head - baseDistance must been persisted
    checkPersisted(chain, blk3)

    # It is FC module who is responsible for saving
    # finalized hash on a correct txFrame.
    let txFrame = chain.txFrame(blk6.blockHash)
    let savedFinalized = txFrame.fcuFinalized().expect("OK")
    check blk6.blockHash == savedFinalized.hash

    # make sure aristo not wipe out baggage
    check chain.wdWritten(blk3) == 3
    check chain.validate info & " (9)"

  test "newBase between oldBase and head":
    const info = "newBase between oldBase and head"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 0)
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
    checkHeadHash chain, blk7.blockHash
    check chain.latestHash == blk7.blockHash
    check chain.heads.len == 1
    check chain.wdWritten(blk6) == 6
    check chain.wdWritten(blk7) == 7
    # head - baseDistance must been persisted
    checkPersisted(chain, blk3)
    # make sure aristo not wipe out baggage
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
    checkHeadHash chain, B7.blockHash
    check chain.latestHash == B7.blockHash
    check chain.baseNumber == 0'u64
    check chain.heads.len == 1 # B become canonical
    check chain.hashToBlock.len == 8 # 0,1,2,3,B4,B5,B6,B7
    check chain.validate info & " (9)"

  test "newBase move forward, fork and stay on that fork":
    const info = "newBase move forward, fork .."
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 0)
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
    checkHeadHash chain, B6.blockHash
    check chain.latestHash == B7.blockHash
    check chain.baseNumber == 3'u64
    check chain.heads.len == 1
    check chain.validate info & " (9)"

  test "newBase on shorter canonical arc, remove oldBase branches":
    const info = "newBase on shorter canonical, remove oldBase branches"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 0)
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
    checkHeadHash chain, B7.blockHash
    check chain.latestHash == B7.blockHash
    check chain.baseNumber == 4'u64
    check chain.heads.len == 1
    check chain.validate info & " (9)"

  test "newBase on curbed non-canonical arc":
    const info = "newBase on curbed non-canonical .."
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 5, persistBatchSize = 0)
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
    checkHeadHash chain, B7.blockHash
    check chain.latestHash == B7.blockHash
    check chain.baseNumber > 0
    check chain.baseNumber < B4.header.number
    check chain.heads.len == 1
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
    checkHeadHash chain, blk7.blockHash
    check chain.latestHash == blk7.blockHash
    check chain.baseNumber == 0'u64
    check chain.heads.len == 1
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
    checkForkChoice(chain, blk7, blk6)
    check chain.validate info & " (2)"
    checkHeadHash chain, blk7.blockHash
    check chain.latestHash == blk7.blockHash
    check chain.heads.len == 1
    check chain.base.number == 4
    check chain.validate info & " (9)"

  test "newBase on shorter canonical arc, discard arc with oldBase" &
       " (ign dup block)":
    const info = "newBase on shorter canonical .."
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 0)
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
    checkHeadHash chain, B7.blockHash
    check chain.latestHash == B7.blockHash
    check chain.baseNumber == 4'u64
    check chain.heads.len == 1
    check chain.validate info & " (9)"

  test "newBase on longer canonical arc, discard new branch":
    const info = "newBase on longer canonical .."
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 0)
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
    checkHeadHash chain, blk7.blockHash
    check chain.latestHash == blk7.blockHash
    check chain.baseNumber > 0
    check chain.baseNumber < blk5.header.number
    check chain.heads.len == 1
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
    check chain.headerByNumber(7).expect("OK").computeBlockHash == blk7.blockHash
    # from db
    check chain.headerByNumber(3).expect("OK").number == 3
    check chain.headerByNumber(3).expect("OK").computeBlockHash == blk3.blockHash
    # base
    check chain.headerByNumber(4).expect("OK").number == 4
    check chain.headerByNumber(4).expect("OK").computeBlockHash == blk4.blockHash
    # from cache
    check chain.headerByNumber(5).expect("OK").number == 5
    check chain.headerByNumber(5).expect("OK").computeBlockHash == blk5.blockHash
    check chain.validate info & " (9)"

  test "3 branches, alternating imports":
    const info = "3 branches, alternating imports"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3)
    checkImportBlock(chain, blk1)
    checkImportBlock(chain, blk2)
    checkImportBlock(chain, blk3)
    checkImportBlock(chain, B4)
    checkImportBlock(chain, blk4)
    checkImportBlock(chain, B5)
    checkImportBlock(chain, blk5)
    checkImportBlock(chain, C5)
    checkImportBlock(chain, B6)
    checkImportBlock(chain, blk6)
    checkImportBlock(chain, C6)
    checkImportBlock(chain, B7)
    checkImportBlock(chain, blk7)
    checkImportBlock(chain, C7)
    check chain.validate info & " (1)"
    check chain.latestHash == C7.blockHash
    check chain.latestNumber == 7'u64
    check chain.heads.len == 3
    checkForkChoice(chain, B7, blk3)
    check chain.validate info & " (2)"
    check chain.heads.len == 3
    checkForkChoice(chain, B7, B6)
    check chain.validate info & " (2)"
    check chain.heads.len == 1

  test "importing blocks with new CommonRef and FC instance, 3 blocks":
    const info = "importing blocks with new CommonRef and FC instance, 3 blocks"
    let com = env.newCom()
    let chain = ForkedChainRef.init(com, baseDistance = 0, persistBatchSize = 0)
    checkImportBlock(chain, blk1)
    checkImportBlock(chain, blk2)
    checkImportBlock(chain, blk3)
    checkForkChoice(chain, blk3, blk3)
    check chain.validate info & " (1)"
    let cc = env.newCom(com.db)
    let fc = ForkedChainRef.init(cc, baseDistance = 0, persistBatchSize = 0)
    checkHeadHash fc, blk3.blockHash
    checkImportBlock(fc, blk4)
    checkForkChoice(fc, blk4, blk4)
    check chain.validate info & " (2)"

  test "importing blocks with new CommonRef and FC instance, 1 block":
    const info = "importing blocks with new CommonRef and FC instance, 1 block"
    let com = env.newCom()
    let chain = ForkedChainRef.init(com, baseDistance = 0, persistBatchSize = 0)
    checkImportBlock(chain, blk1)
    checkForkChoice(chain, blk1, blk1)
    check chain.validate info & " (1)"
    let cc = env.newCom(com.db)
    let fc = ForkedChainRef.init(cc, baseDistance = 0, persistBatchSize = 0)
    checkHeadHash fc, blk1.blockHash
    checkImportBlock(fc, blk2)
    checkForkChoice(fc, blk2, blk2)
    check chain.validate info & " (2)"

  test "newBase move forward, greater than persistBatchSize":
    const info = "newBase move forward, greater than persistBatchSize"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 2)
    checkImportBlock(chain, blk1)
    checkImportBlock(chain, blk2)
    checkImportBlock(chain, blk3)
    checkImportBlock(chain, blk4)
    checkImportBlock(chain, blk5)
    checkImportBlock(chain, blk6)
    checkImportBlock(chain, blk7)

    check chain.validate info & " (1)"
    checkForkChoice(chain, blk7, blk4)
    check chain.validate info & " (2)"

    checkHeadHash chain, blk7.blockHash
    check chain.latestHash == blk7.blockHash

    check chain.baseNumber == 4'u64
    check chain.heads.len == 1
    check chain.validate info & " (9)"

  test "newBase move forward, equal persistBatchSize":
    const info = "newBase move forward, equal persistBatchSize"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 2)
    checkImportBlock(chain, blk1)
    checkImportBlock(chain, blk2)
    checkImportBlock(chain, blk3)
    checkImportBlock(chain, blk4)
    checkImportBlock(chain, blk5)
    checkImportBlock(chain, blk6)
    checkImportBlock(chain, blk7)

    check chain.validate info & " (1)"
    checkForkChoice(chain, blk7, blk2)
    check chain.validate info & " (2)"

    checkHeadHash chain, blk7.blockHash
    check chain.latestHash == blk7.blockHash

    check chain.baseNumber == 2'u64
    check chain.heads.len == 1
    check chain.validate info & " (9)"

  test "newBase move forward, lower than persistBatchSize":
    const info = "newBase move forward, lower than persistBatchSize"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 2)
    checkImportBlock(chain, blk1)
    checkImportBlock(chain, blk2)
    checkImportBlock(chain, blk3)
    checkImportBlock(chain, blk4)
    checkImportBlock(chain, blk5)
    checkImportBlock(chain, blk6)
    checkImportBlock(chain, blk7)

    check chain.validate info & " (1)"
    checkForkChoice(chain, blk7, blk1)
    check chain.validate info & " (2)"

    checkHeadHash chain, blk7.blockHash
    check chain.latestHash == blk7.blockHash

    check chain.baseNumber == 0'u64
    check chain.heads.len == 1
    check chain.validate info & " (9)"

  test "newBase move forward, auto mode":
    const info = "newBase move forward, auto mode"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 2)
    check (waitFor chain.forkChoice(blk7.blockHash, blk6.blockHash)).isErr
    check chain.tryUpdatePendingFCU(blk6.blockHash, blk6.header.number)
    checkImportBlock(chain, blk1)
    checkImportBlock(chain, blk2)
    checkImportBlock(chain, blk3)
    checkImportBlock(chain, blk4)
    checkImportBlock(chain, blk5)
    checkImportBlock(chain, blk6)
    checkImportBlock(chain, blk7)

    check chain.validate info & " (1)"

    checkHeadHash chain, blk2.blockHash
    check chain.latestHash == blk7.blockHash

    check chain.baseNumber == 2'u64
    check chain.heads.len == 1
    check chain.validate info & " (2)"

  test "newBase move forward, auto mode no forkChoice":
    const info = "newBase move forward, auto mode no forkChoice"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 3, persistBatchSize = 2)

    check chain.tryUpdatePendingFCU(blk5.blockHash, blk5.header.number)
    checkImportBlock(chain, blk1)
    checkImportBlock(chain, blk2)
    checkImportBlock(chain, blk3)
    checkImportBlock(chain, blk4)
    checkImportBlock(chain, blk5)
    checkImportBlock(chain, blk6)
    checkImportBlock(chain, blk7)

    check chain.validate info & " (1)"

    checkHeadHash chain, genesisHash
    check chain.latestHash == blk7.blockHash

    check chain.baseNumber == 0'u64
    check chain.heads.len == 1
    check chain.validate info & " (2)"

  test "newBase move forward, auto mode, base finalized marker needed":
    const info = "newBase move forward, auto mode, base finalized marker needed"
    let com = env.newCom()
    var chain = ForkedChainRef.init(com, baseDistance = 2, persistBatchSize = 1)
    check (waitFor chain.forkChoice(blk8.blockHash, blk8.blockHash)).isErr
    check chain.tryUpdatePendingFCU(blk8.blockHash, blk8.header.number)
    checkImportBlock(chain, blk1)
    checkImportBlock(chain, blk2)
    checkImportBlock(chain, blk3)
    checkImportBlock(chain, B4)
    checkImportBlock(chain, blk4)
    checkImportBlock(chain, B5)
    checkImportBlock(chain, C5)
    checkImportBlock(chain, blk5)
    checkImportBlock(chain, blk6)
    checkImportBlock(chain, blk7)
    checkImportBlock(chain, blk8)

    check chain.validate info & " (1)"

    checkHeadHash chain, blk5.blockHash
    check chain.latestHash == blk8.blockHash

    check chain.baseNumber == 5'u64
    check chain.heads.len == 1
    check chain.validate info & " (2)"

  test "serialize roundtrip":
    const info = "serialize roundtrip"
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
    checkHeadHash chain, blk7.blockHash
    check chain.baseNumber == 4'u64
    check chain.latestHash == blk7.blockHash
    check chain.validate info & " (3)"

    let txFrame = chain.baseTxFrame
    let src = chain.serialize(txFrame)
    if src.isErr:
      echo "FAILED TO SERIALIZE: ", src.error
    check src.isOk
    com.db.persist(txFrame)

    var fc = ForkedChainRef.init(com, baseDistance = 3)
    let rc = fc.deserialize()
    if rc.isErr:
      echo "FAILED TO DESERIALIZE: ", rc.error
    check rc.isOk

    check fc.heads.len == chain.heads.len
    check fc.hashToBlock.len == chain.hashToBlock.len

    checkHeadHash fc, blk7.blockHash
    check fc.latestHash == chain.latestHash
    check fc.validate info & " (4)"

procSuite "ForkedChain mainnet replay":
  # A short mainnet replay test to check that the first few hundred blocks can
  # be imported using a typical importBlock / fcu sequence - this does not
  # test any transactions since these blocks are practically empty, but thanks
  # to block rewards the state db keeps changing anyway providing a simple
  # smoke test
  setup:
    let
      era0 = Era1DbRef.init(sourcePath / "replay", "mainnet").expect("Era files present")
      com = CommonRef.new(AristoDbMemory.newCoreDbRef(), nil)
      fc = ForkedChainRef.init(com, enableQueue = true)

  asyncTest "Replay mainnet era, single FCU":
    var blk: EthBlock
    for i in 1..<fc.baseDistance * 10:
      era0.getEthBlock(i.BlockNumber, blk).expect("block in test database")
      check (await fc.queueImportBlock(blk)).isOk()

    check (await fc.queueForkChoice(blk.blockHash, blk.blockHash)).isOk()

  asyncTest "Replay mainnet era, multiple FCU":
    # Simulates the typical case where fcu comes after the block
    var blk: EthBlock
    era0.getEthBlock(0.BlockNumber, blk).expect("block in test database")

    var blocks = [blk.blockHash, blk.blockHash]

    for i in 1..<fc.baseDistance * 10:
      era0.getEthBlock(i.BlockNumber, blk).expect("block in test database")
      check (await fc.queueImportBlock(blk)).isOk()

      let hash = blk.blockHash
      check (await fc.queueForkChoice(hash, blocks[0])).isOk()
      if i mod 32 == 0:
        # in reality, finalized typically lags a bit more than this, but
        # for the purpose of the test, this should be good enough
        blocks[0] = blocks[1]
        blocks[1] = hash

  asyncTest "Replay mainnet era, invalid blocks":
    var
      blk1: EthBlock
      invalidBlk: EthBlock
      blk2: EthBlock
      blk3: EthBlock

    era0.getEthBlock(1.BlockNumber, blk1).expect("block in test database")
    era0.getEthBlock(2.BlockNumber, invalidBlk).expect("block in test database")
    invalidBlk.header.stateRoot = blk2.header.transactionsRoot
    era0.getEthBlock(2.BlockNumber, blk2).expect("block in test database")
    era0.getEthBlock(3.BlockNumber, blk3).expect("block in test database")

    check (await fc.queueImportBlock(blk1)).isOk()
    for i in 1..10:
      check (await fc.queueImportBlock(invalidBlk)).isErr()
    check (await fc.queueImportBlock(blk2)).isOk()
    check (await fc.queueImportBlock(blk3)).isOk()

  asyncTest "Concurrent block imports - stateroot check enabled":
    let fc = ForkedChainRef.init(com, eagerStateRoot = true)

    var
      blk1: EthBlock
      invalidBlk: EthBlock
      blk2: EthBlock

    era0.getEthBlock(1.BlockNumber, blk1).expect("block in test database")
    era0.getEthBlock(2.BlockNumber, invalidBlk).expect("block in test database")
    invalidBlk.header.coinbase = blk1.header.coinbase
    era0.getEthBlock(2.BlockNumber, blk2).expect("block in test database")

    check (await fc.importBlock(blk1)).isOk()

    var futs: seq[Future[Result[void, string]]]
    for i in 1..10:
      futs.add fc.importBlock(invalidBlk)

    let finishedFuts = await allFinished(futs)
    for f in finishedFuts:
      check (await f).isErr()

    check (await fc.importBlock(blk2)).isOk()
