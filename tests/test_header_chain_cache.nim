# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Header chain cache: sync headers are stored at their final KVT location
## and cleaned up unless owned by the `FC` module.

{.push raises: [].}

import
  pkg/chronos,
  pkg/unittest2,
  ../execution_chain/common,
  ../execution_chain/conf,
  ../execution_chain/core/chain/[forked_chain, header_chain_cache],
  ../execution_chain/db/[ledger, storage_types],
  ../execution_chain/db/core_db/memory_only

const
  genesisFile = "tests/customgenesis/cancun123.json"
  senderAddr  = address"73cf19657412508833f618a15e8251306b3e6ee5"

proc newCom(): CommonRef =
  let
    config = makeConfig(@["--network:" & genesisFile])
    params = config.computeNetworkParams()
  CommonRef.new(newCoreDbRef DefaultDbMemory, params)

proc makeBlk(txFrame: CoreDbTxRef, number: BlockNumber, parentBlk: Block): Block =
  template parent(): Header =
    parentBlk.header

  var wds = newSeqOfCap[Withdrawal](number.int)
  for i in 0..<number:
    wds.add Withdrawal(index: i, validatorIndex: 1, address: senderAddr, amount: 1)

  let ledger = LedgerRef.init(txFrame)
  for wd in wds:
    ledger.addBalance(wd.address, wd.weiAmount)
  ledger.persist()

  let
    wdRoot = calcWithdrawalsRoot(wds)
    body = BlockBody(withdrawals: Opt.some(move(wds)))
    header = Header(
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
      parentBeaconBlockRoot: parent.parentBeaconBlockRoot)

  Block.init(header, body)

func hash(blk: Block): Hash32 =
  blk.header.computeBlockHash

proc importOk(chain: ForkedChainRef, blk: Block): bool =
  try:
    (waitFor chain.importBlock(blk)).isOk
  except CancelledError:
    false

proc onDisk(chain: ForkedChainRef, blk: Block): bool =
  chain.baseTxFrame.hasKey(genericHashKey(blk.hash).toOpenArray)

proc noSessionData(chain: ForkedChainRef, maxBn: BlockNumber): bool =
  let db = chain.baseTxFrame
  if db.hasKey(syncHeaderInfoKey().toOpenArray):
    return false
  for bn in 0'u64 .. maxBn:
    if db.hasKey(beaconHeaderKey(bn).toOpenArray):
      return false
  true

suite "Header chain cache on KVT proper":
  let
    com = newCom()
    genesis = Block.init(com.genesisHeader, BlockBody())
    txFrame = com.db.baseTxFrame().txFrameBegin
    blk1 = txFrame.makeBlk(1, genesis)
    blk2 = txFrame.makeBlk(2, blk1)
    blk3 = txFrame.makeBlk(3, blk2)
    blk4 = txFrame.makeBlk(4, blk3)
    blk5 = txFrame.makeBlk(5, blk4)
    blk6 = txFrame.makeBlk(6, blk5)
  txFrame.dispose()

  proc setup(): (ForkedChainRef, HeaderChainRef) =
    let
      chain = ForkedChainRef.init(newCom())
      hc = HeaderChainRef.init(chain)
    check chain.importOk(blk1)
    check chain.importOk(blk2)
    hc.start(proc() = discard)
    # Session head is blk6, finalised hash set to the head
    hc.headTargetUpdate(blk6.header, blk6.hash)
    check hc.state == collecting
    # Headers in reverse order, blk3 links to blk2 on the FC module
    check hc.put([blk5.header, blk4.header, blk3.header]).isOk
    check hc.state == ready
    (chain, hc)

  test "Session headers stored at their final location":
    let (chain, hc) = setup()
    for blk in [blk3, blk4, blk5, blk6]:
      check chain.onDisk(blk)
      check chain.baseTxFrame.getBlockHeader(blk.hash).expect("hdr") == blk.header
      check hc.get(blk.header.number).expect("hdr") == blk.header
      check hc.get(blk.hash).expect("hdr") == blk.header
      check hc.getHash(blk.header.number).expect("hash") == blk.hash
    check hc.antecedent == blk3.header
    # Not imported, so invisible to FC lookups
    for blk in [blk3, blk4, blk5, blk6]:
      check chain.headerByHash(blk.hash).isErr
    # FC header that is not a session header is not returned by the cache
    check hc.get(blk1.hash).isErr
    check hc.get(blk1.header.number).isErr

  test "Clear keeps FC-owned headers, deletes the rest":
    let (chain, hc) = setup()
    check hc.commit().isOk
    check hc.state == locked
    check chain.importOk(blk3)
    check chain.importOk(blk4)
    hc.clear()
    check chain.onDisk(blk3)
    check chain.onDisk(blk4)
    check not chain.onDisk(blk5)
    check not chain.onDisk(blk6)
    check chain.onDisk(blk1)
    check chain.onDisk(blk2)
    check chain.noSessionData(10)
    check chain.headerByHash(blk4.hash).expect("hdr") == blk4.header

  test "Restart without clear runs the clean up":
    let (chain, hc) = setup()
    check chain.importOk(blk3)
    # Simulate restart: drop descriptor without clearing, then re-init
    hc.stop()
    discard HeaderChainRef.init(chain)
    check chain.onDisk(blk3)
    for blk in [blk4, blk5, blk6]:
      check not chain.onDisk(blk)
    check chain.noSessionData(10)
