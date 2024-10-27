# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../nimbus/common,
  ../nimbus/config,
  ../nimbus/utils/utils,
  ../nimbus/core/chain/forked_chain,
  ../nimbus/db/ledger,
  unittest2

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
      env.conf.networkId,
      env.conf.networkParams
    )

proc makeBlk(com: CommonRef, number: BlockNumber, parentBlk: Block): Block =
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

  let ledger = LedgerRef.init(com.db)
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

proc makeBlk(com: CommonRef, number: BlockNumber, parentBlk: Block, extraData: byte): Block =
  var blk = com.makeBlk(number, parentBlk)
  blk.header.extraData = @[extraData]
  blk

proc headHash(c: CommonRef): Hash32 =
  c.db.getCanonicalHead().blockHash

func blockHash(x: Block): Hash32 =
  x.header.blockHash

proc wdWritten(com: CommonRef, blk: Block): int =
  if blk.header.withdrawalsRoot.isSome:
    com.db.getWithdrawals(blk.header.withdrawalsRoot.get).len
  else:
    0

proc forkedChainMain*() =
  suite "ForkedChainRef tests":
    var env = setupEnv()
    let
      cc = env.newCom
      genesisHash = cc.genesisHeader.blockHash
      genesis = Block.init(cc.genesisHeader, BlockBody())

    let
      blk1 = cc.makeBlk(1, genesis)
      blk2 = cc.makeBlk(2, blk1)
      blk3 = cc.makeBlk(3, blk2)

      dbTx = cc.db.ctx.newTransaction()
      blk4 = cc.makeBlk(4, blk3)
      blk5 = cc.makeBlk(5, blk4)
      blk6 = cc.makeBlk(6, blk5)
      blk7 = cc.makeBlk(7, blk6)

    dbTx.dispose()

    let
      B4 = cc.makeBlk(4, blk3, 1.byte)
      B5 = cc.makeBlk(5, B4)
      B6 = cc.makeBlk(6, B5)
      B7 = cc.makeBlk(7, B6)

    test "newBase == oldBase":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader)
      check chain.importBlock(blk1).isOk

      # same header twice
      check chain.importBlock(blk1).isOk

      check chain.importBlock(blk2).isOk

      check chain.importBlock(blk3).isOk

      # no parent
      check chain.importBlock(blk5).isErr

      check com.headHash == genesisHash
      check chain.latestHash == blk3.blockHash

      # finalized > head -> error
      check chain.forkChoice(blk1.blockHash, blk3.blockHash).isErr

      # blk4 is not part of chain
      check chain.forkChoice(blk4.blockHash, blk2.blockHash).isErr

      # finalized > head -> error
      check chain.forkChoice(blk1.blockHash, blk2.blockHash).isErr

      # blk4 is not part of chain
      check chain.forkChoice(blk2.blockHash, blk4.blockHash).isErr

      # finalized < head -> ok
      check chain.forkChoice(blk2.blockHash, blk1.blockHash).isOk
      check com.headHash == blk2.blockHash
      check chain.latestHash == blk2.blockHash

      # finalized == head -> ok
      check chain.forkChoice(blk2.blockHash, blk2.blockHash).isOk
      check com.headHash == blk2.blockHash
      check chain.latestHash == blk2.blockHash

      # no baggage written
      check com.wdWritten(blk1) == 0
      check com.wdWritten(blk2) == 0

    test "newBase == cursor":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader, baseDistance = 3)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(blk4).isOk

      # newbase == cursor
      check chain.forkChoice(blk7.blockHash, blk6.blockHash).isOk

      check com.headHash == blk7.blockHash
      check chain.latestHash == blk7.blockHash

      check com.wdWritten(blk7) == 0

      # head - baseDistance must been finalized
      check com.wdWritten(blk4) == 4
      # make sure aristo not wiped out baggage
      check com.wdWritten(blk3) == 3

    test "newBase between oldBase and cursor":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader, baseDistance = 3)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.forkChoice(blk7.blockHash, blk6.blockHash).isOk

      check com.headHash == blk7.blockHash
      check chain.latestHash == blk7.blockHash

      check com.wdWritten(blk6) == 0
      check com.wdWritten(blk7) == 0

      # head - baseDistance must been finalized
      check com.wdWritten(blk4) == 4
      # make sure aristo not wiped out baggage
      check com.wdWritten(blk3) == 3

    test "newBase == oldBase, fork and keep on that fork":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(B4).isOk
      check chain.importBlock(B5).isOk
      check chain.importBlock(B6).isOk
      check chain.importBlock(B7).isOk

      check chain.forkChoice(B7.blockHash, B5.blockHash).isOk

      check com.headHash == B7.blockHash
      check chain.latestHash == B7.blockHash

    test "newBase == cursor, fork and keep on that fork":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader, baseDistance = 3)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(B4).isOk
      check chain.importBlock(B5).isOk
      check chain.importBlock(B6).isOk
      check chain.importBlock(B7).isOk

      check chain.importBlock(B4).isOk

      check chain.forkChoice(B7.blockHash, B6.blockHash).isOk

      check com.headHash == B7.blockHash
      check chain.latestHash == B7.blockHash

    test "newBase between oldBase and cursor, fork and keep on that fork":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader, baseDistance = 3)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(B4).isOk
      check chain.importBlock(B5).isOk
      check chain.importBlock(B6).isOk
      check chain.importBlock(B7).isOk

      check chain.forkChoice(B7.blockHash, B5.blockHash).isOk

      check com.headHash == B7.blockHash
      check chain.latestHash == B7.blockHash

    test "newBase == oldBase, fork and return to old chain":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(B4).isOk
      check chain.importBlock(B5).isOk
      check chain.importBlock(B6).isOk
      check chain.importBlock(B7).isOk

      check chain.forkChoice(blk7.blockHash, blk5.blockHash).isOk

      check com.headHash == blk7.blockHash
      check chain.latestHash == blk7.blockHash

    test "newBase == cursor, fork and return to old chain":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader, baseDistance = 3)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(B4).isOk
      check chain.importBlock(B5).isOk
      check chain.importBlock(B6).isOk
      check chain.importBlock(B7).isOk

      check chain.importBlock(blk4).isOk

      check chain.forkChoice(blk7.blockHash, blk5.blockHash).isOk

      check com.headHash == blk7.blockHash
      check chain.latestHash == blk7.blockHash

    test "newBase between oldBase and cursor, fork and return to old chain, switch to new chain":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader, baseDistance = 3)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(B4).isOk
      check chain.importBlock(B5).isOk
      check chain.importBlock(B6).isOk
      check chain.importBlock(B7).isOk

      check chain.importBlock(blk4).isOk

      check chain.forkChoice(B7.blockHash, B5.blockHash).isOk

      check com.headHash == B7.blockHash
      check chain.latestHash == B7.blockHash

    test "newBase between oldBase and cursor, fork and return to old chain":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader, baseDistance = 3)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(B4).isOk
      check chain.importBlock(B5).isOk
      check chain.importBlock(B6).isOk
      check chain.importBlock(B7).isOk

      check chain.forkChoice(blk7.blockHash, blk5.blockHash).isOk

      check com.headHash == blk7.blockHash
      check chain.latestHash == blk7.blockHash

    test "headerByNumber":
      let com = env.newCom()

      var chain = newForkedChain(com, com.genesisHeader, baseDistance = 3)
      check chain.importBlock(blk1).isOk
      check chain.importBlock(blk2).isOk
      check chain.importBlock(blk3).isOk
      check chain.importBlock(blk4).isOk
      check chain.importBlock(blk5).isOk
      check chain.importBlock(blk6).isOk
      check chain.importBlock(blk7).isOk

      check chain.importBlock(B4).isOk
      check chain.importBlock(B5).isOk
      check chain.importBlock(B6).isOk
      check chain.importBlock(B7).isOk

      check chain.forkChoice(blk7.blockHash, blk5.blockHash).isOk

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

when isMainModule:
  forkedChainMain()
