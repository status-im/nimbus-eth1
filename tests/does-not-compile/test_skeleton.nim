import
  unittest2,
  chronicles,
  stew/[results, byteutils],
  eth/[common, trie/db],
  ../nimbus/sync/skeleton,
  ../nimbus/db/db_chain,
  ../nimbus/p2p/chain,
  ../nimbus/[chain_config, config, genesis, constants],
  ./test_helpers,
  ./test_txpool/helpers

const
  baseDir = [".", "tests"]
  repoDir = [".", "customgenesis"]
  genesisFile = "post-merge.json"

type
  Subchain = object
    head: int
    tail: int

  TestEnv = object
    conf    : NimbusConf
    chainDB : ChainDBRef
    chain   : Chain

  CCModify = proc(cc: NetworkParams)

# TODO: too bad that blockHash
# cannot be executed at compile time
let
  block49 = BlockHeader(
    blockNumber: 49.toBlockNumber
  )
  block49B = BlockHeader(
    blockNumber: 49.toBlockNumber,
    extraData: @['B'.byte]
  )
  block50 = BlockHeader(
    blockNumber: 50.toBlockNumber,
    parentHash: block49.blockHash
  )
  block51 = BlockHeader(
    blockNumber: 51.toBlockNumber,
    parentHash: block50.blockHash
  )

proc initEnv(ccm: CCModify = nil): TestEnv =
  let
    conf = makeConfig(@[
      "--custom-network:" & genesisFile.findFilePath(baseDir,repoDir).value
    ])

  if ccm.isNil.not:
    ccm(conf.networkParams)

  let
    chainDB = newChainDBRef(
      newCoreDbRef LegacyDbMemory,
      conf.pruneMode == PruneMode.Full,
      conf.networkId,
      conf.networkParams
    )
    chain = newChain(chainDB)

  initializeEmptyDb(chainDB)

  result = TestEnv(
    conf: conf,
    chainDB: chainDB,
    chain: chain
  )

proc `subchains=`(sk: SkeletonRef, subchains: openArray[Subchain]) =
  var sc = newSeqOfCap[SkeletonSubchain](subchains.len)
  for i in 0..<subchains.len:
    let x = subchains[i]
    sc.add(SkeletonSubchain(
      head: x.head.toBlockNumber,
      tail: x.tail.toBlockNumber
    ))
  sk.subchains = sc

suite "syncInit":
  # Tests various sync initializations based on previous leftovers in the database
  # and announced heads.

  type
    TestCase = object
      blocks  : seq[BlockHeader] # Database content (besides the genesis)
      oldState: seq[Subchain]    # Old sync state with various interrupted subchains
      head    : BlockHeader      # New head header to announce to reorg to
      newState: seq[Subchain]    # Expected sync state after the reorg

  let testCases = [
    # Completely empty database with only the genesis set. The sync is expected
    # to create a single subchain with the requested head.
    TestCase(
      head: block50,
      newState: @[SubChain(head: 50, tail: 50)]
    ),
    # Empty database with only the genesis set with a leftover empty sync
    # progress. This is a synthetic case, just for the sake of covering things.
    TestCase(
      head: block50,
      newState: @[SubChain(head: 50, tail: 50)]
    ),
    # A single leftover subchain is present, older than the new head. The
    # old subchain should be left as is and a new one appended to the sync
    # status.
    TestCase(
      oldState: @[SubChain(head: 10, tail: 5)],
      head: block50,
      newState: @[
        SubChain(head: 50, tail: 50),
        SubChain(head: 10, tail: 5)
      ]
    ),
    # Multiple leftover subchains are present, older than the new head. The
    # old subchains should be left as is and a new one appended to the sync
    # status.
    TestCase(
      oldState: @[
        SubChain(head: 20, tail: 15),
        SubChain(head: 10, tail: 5)
      ],
      head: block50,
      newState: @[
        SubChain(head: 50, tail: 50),
        SubChain(head: 20, tail: 15),
        SubChain(head: 10, tail: 5)
      ]
    ),
    # A single leftover subchain is present, newer than the new head. The
    # newer subchain should be deleted and a fresh one created for the head.
    TestCase(
      oldState: @[SubChain(head: 65, tail: 60)],
      head: block50,
      newState: @[SubChain(head: 50, tail: 50)]
    ),
    # Multiple leftover subchain is present, newer than the new head. The
    # newer subchains should be deleted and a fresh one created for the head.
    TestCase(
      oldState: @[
        SubChain(head: 75, tail: 70),
        SubChain(head: 65, tail: 60)
      ],
      head: block50,
      newState: @[SubChain(head: 50, tail: 50)]
    ),
    # Two leftover subchains are present, one fully older and one fully
    # newer than the announced head. The head should delete the newer one,
    # keeping the older one.
    TestCase(
      oldState: @[
        SubChain(head: 65, tail: 60),
        SubChain(head: 10, tail: 5),
      ],
      head: block50,
      newState: @[
        SubChain(head: 50, tail: 50),
        SubChain(head: 10, tail: 5),
      ],
    ),
    # Multiple leftover subchains are present, some fully older and some
    # fully newer than the announced head. The head should delete the newer
    # ones, keeping the older ones.
    TestCase(
      oldState: @[
        SubChain(head: 75, tail: 70),
        SubChain(head: 65, tail: 60),
        SubChain(head: 20, tail: 15),
        SubChain(head: 10, tail: 5),
      ],
      head: block50,
      newState: @[
        SubChain(head: 50, tail: 50),
        SubChain(head: 20, tail: 15),
        SubChain(head: 10, tail: 5),
      ],
    ),
    # A single leftover subchain is present and the new head is extending
    # it with one more header. We expect the subchain head to be pushed
    # forward.
    TestCase(
      blocks: @[block49],
      oldState: @[SubChain(head: 49, tail: 5)],
      head: block50,
      newState: @[SubChain(head: 50, tail: 5)]
    ),
    # A single leftover subchain is present. A new head is announced that
    # links into the middle of it, correctly anchoring into an existing
    # header. We expect the old subchain to be truncated and extended with
    # the new head.
    TestCase(
      blocks: @[block49],
      oldState: @[SubChain(head: 100, tail: 5)],
      head: block50,
      newState: @[SubChain(head: 50, tail: 5)]
    ),
    # A single leftover subchain is present. A new head is announced that
    # links into the middle of it, but does not anchor into an existing
    # header. We expect the old subchain to be truncated and a new chain
    # be created for the dangling head.
    TestCase(
      blocks: @[block49B],
      oldState: @[SubChain(head: 100, tail: 5)],
      head: block50,
      newState: @[
        SubChain(head: 50, tail: 50),
        SubChain(head: 49, tail: 5),
      ]
    )
  ]

  for z, testCase in testCases:
    test "test case #" & $z:
      let env = initEnv()
      let skeleton = SkeletonRef.new(env.chain)
      skeleton.open()

      for header in testCase.blocks:
        skeleton.putHeader(header)

      if testCase.oldState.len > 0:
        skeleton.subchains = testCase.oldState

      skeleton.initSync(testCase.head)

      check skeleton.len == testCase.newState.len
      for i, sc in skeleton:
        check sc.head == testCase.newState[i].head.toBlockNumber
        check sc.tail == testCase.newState[i].tail.toBlockNumber

suite "sync extend":
  type
    TestCase = object
      head    : BlockHeader   # New head header to announce to reorg to
      extend  : BlockHeader   # New head header to announce to extend with
      newState: seq[Subchain] # Expected sync state after the reorg
      err     : string        # Whether extension succeeds or not

  let testCases = [
    # Initialize a sync and try to extend it with a subsequent block.
    TestCase(
      head: block49,
      extend: block50,
      newState: @[Subchain(head: 50, tail: 49)],
    ),
    # Initialize a sync and try to extend it with the existing head block.
    TestCase(
      head: block49,
      extend: block49,
      newState: @[Subchain(head: 49, tail: 49)],
    ),
    # Initialize a sync and try to extend it with a sibling block.
    TestCase(
      head: block49,
      extend: block49B,
      newState: @[Subchain(head: 49, tail: 49)],
      err: "ErrReorgDenied",
    ),
    # Initialize a sync and try to extend it with a number-wise sequential
    # header, but a hash wise non-linking one.
    TestCase(
      head: block49B,
      extend: block50,
      newState: @[Subchain(head: 49, tail: 49)],
      err: "ErrReorgDenied",
    ),
    # Initialize a sync and try to extend it with a non-linking future block.
    TestCase(
      head: block49,
      extend: block51,
      newState: @[Subchain(head: 49, tail: 49)],
      err: "ErrReorgDenied",
    ),
    # Initialize a sync and try to extend it with a past canonical block.
    TestCase(
      head: block50,
      extend: block49,
      newState: @[Subchain(head: 50, tail: 50)],
      err: "ErrReorgDenied",
    ),
    # Initialize a sync and try to extend it with a past sidechain block.
    TestCase(
      head: block50,
      extend: block49B,
      newState: @[Subchain(head: 50, tail: 50)],
      err: "ErrReorgDenied",
    )
  ]

  for z, testCase in testCases:
    test "test case #" & $z:
      let env = initEnv()
      let skeleton = SkeletonRef.new(env.chain)
      skeleton.open()

      skeleton.initSync(testCase.head)

      try:
        skeleton.setHead(testCase.extend)
        check testCase.err.len == 0
      except Exception as e:
        check testCase.err.len > 0
        check testCase.err == e.name

      check skeleton.len == testCase.newState.len
      for i, sc in skeleton:
        check sc.head == testCase.newState[i].head.toBlockNumber
        check sc.tail == testCase.newState[i].tail.toBlockNumber


template testCond(expr: untyped) =
  if not (expr):
    return TestStatus.Failed

template testCond(expr, body: untyped) =
  if not (expr):
    body
    return TestStatus.Failed

proc linkedToGenesis(env: TestEnv): TestStatus =
  result = TestStatus.OK
  env.chain.validateBlock = false
  let skeleton = SkeletonRef.new(env.chain)

  let
    genesis = env.chainDB.getCanonicalHead()
    block1 = BlockHeader(
      blockNumber: 1.toBlockNumber, parentHash: genesis.blockHash, difficulty: 100.u256
    )
    block2 = BlockHeader(
      blockNumber: 2.toBlockNumber, parentHash: block1.blockHash, difficulty: 100.u256
    )
    block3 = BlockHeader(
      blockNumber: 3.toBlockNumber, parentHash: block2.blockHash, difficulty: 100.u256
    )
    block4 = BlockHeader(
      blockNumber: 4.toBlockNumber, parentHash: block3.blockHash, difficulty: 100.u256
    )
    block5 = BlockHeader(
      blockNumber: 5.toBlockNumber, parentHash: block4.blockHash, difficulty: 100.u256
    )

  skeleton.open()
  skeleton.initSync(block4)

  skeleton.ignoreTxs = true
  discard skeleton.putBlocks([block3, block2])
  testCond env.chainDB.currentBlock == 0.toBlockNumber:
    error "canonical height should be at genesis"

  discard skeleton.putBlocks([block1])
  testCond env.chainDB.currentBlock == 4.toBlockNumber:
    error "canonical height should update after being linked"

  skeleton.setHead(block5, false)
  testCond env.chainDB.currentBlock == 4.toBlockNumber:
    error "canonical height should not change when setHead is set with force=false"

  skeleton.setHead(block5, true)
  testCond env.chainDB.currentBlock == 5.toBlockNumber:
    error "canonical height should change when setHead is set with force=true"

  var h: BlockHeader
  for header in [block1, block2, block3, block4, block5]:
    var res = skeleton.getHeader(header.blockNumber, h, true)
    testCond res == false:
      error "skeleton block should be cleaned up after filling canonical chain",
        number=header.blockNumber

    res = skeleton.getHeaderByHash(header.blockHash, h)
    testCond res == false:
      error "skeleton block should be cleaned up after filling canonical chain",
        number=header.blockNumber

proc linkedPastGenesis(env: TestEnv): TestStatus =
  result = TestStatus.OK
  env.chain.validateBlock = false
  let skeleton = SkeletonRef.new(env.chain)

  skeleton.open()
  let
    genesis = env.chainDB.getCanonicalHead()
    block1 = BlockHeader(
      blockNumber: 1.toBlockNumber, parentHash: genesis.blockHash, difficulty: 100.u256
    )
    block2 = BlockHeader(
      blockNumber: 2.toBlockNumber, parentHash: block1.blockHash, difficulty: 100.u256
    )
    block3 = BlockHeader(
      blockNumber: 3.toBlockNumber, parentHash: block2.blockHash, difficulty: 100.u256
    )
    block4 = BlockHeader(
      blockNumber: 4.toBlockNumber, parentHash: block3.blockHash, difficulty: 100.u256
    )
    block5 = BlockHeader(
      blockNumber: 5.toBlockNumber, parentHash: block4.blockHash, difficulty: 100.u256
    )

  var body: BlockBody
  let vr = env.chain.persistBlocks([block1, block2], [body, body])
  testCond vr == ValidationResult.OK

  skeleton.initSync(block4)
  testCond env.chainDB.currentBlock == 2.toBlockNumber:
    error "canonical height should be at block 2"

  skeleton.ignoreTxs = true
  discard skeleton.putBlocks([block3])
  testCond env.chainDB.currentBlock == 4.toBlockNumber:
    error "canonical height should update after being linked"

  skeleton.setHead(block5, false)
  testCond env.chainDB.currentBlock == 4.toBlockNumber:
    error "canonical height should not change when setHead with force=false"

  skeleton.setHead(block5, true)
  testCond env.chainDB.currentBlock == 5.toBlockNumber:
    error "canonical height should change when setHead with force=true"

  var h: BlockHeader
  for header in [block3, block4, block5]:
    var res = skeleton.getHeader(header.blockNumber, h, true)
    testCond res == false:
      error "skeleton block should be cleaned up after filling canonical chain",
        number=header.blockNumber

    res = skeleton.getHeaderByHash(header.blockHash, h)
    testCond res == false:
      error "skeleton block should be cleaned up after filling canonical chain",
        number=header.blockNumber

proc ccmAbortTerminalInvalid(cc: NetworkParams) =
  cc.config.terminalTotalDifficulty = some(200.u256)
  cc.genesis.extraData = hexToSeqByte("0x000000000000000000")
  cc.genesis.difficulty = UInt256.fromHex("0x01")

proc abortTerminalInvalid(env: TestEnv): TestStatus =
  result = TestStatus.OK
  env.chain.validateBlock = false
  let skeleton = SkeletonRef.new(env.chain)

  let
    genesisBlock = env.chainDB.getCanonicalHead()
    block1 = BlockHeader(
      blockNumber: 1.toBlockNumber, parentHash: genesisBlock.blockHash, difficulty: 100.u256
    )
    block2 = BlockHeader(
      blockNumber: 2.toBlockNumber, parentHash: block1.blockHash, difficulty: 100.u256
    )
    block3PoW = BlockHeader(
      blockNumber: 3.toBlockNumber, parentHash: block2.blockHash, difficulty: 100.u256
    )
    block3PoS = BlockHeader(
      blockNumber: 3.toBlockNumber, parentHash: block2.blockHash, difficulty: 0.u256
      #{ common, hardforkByTTD: BigInt(200) }
    )
    block4InvalidPoS = BlockHeader(
      blockNumber: 4.toBlockNumber, parentHash: block3PoW.blockHash, difficulty: 0.u256
      #{ common, hardforkByTTD: BigInt(200) }
    )
    block4PoS = BlockHeader(
      blockNumber: 4.toBlockNumber, parentHash: block3PoS.blockHash, difficulty: 0.u256
      #{ common, hardforkByTTD: BigInt(200) }
    )
    block5 = BlockHeader(
      blockNumber: 5.toBlockNumber, parentHash: block4PoS.blockHash, difficulty: 0.u256
      #{ common, hardforkByTTD: BigInt(200) }
    )

  skeleton.ignoreTxs = true
  skeleton.open()
  skeleton.initSync(block4InvalidPoS)

  discard skeleton.putBlocks([block3PoW, block2])
  testCond env.chainDB.currentBlock == 0.toBlockNumber:
    error "canonical height should be at genesis"

  discard skeleton.putBlocks([block1])
  testCond env.chainDB.currentBlock == 2.toBlockNumber:
    error "canonical height should stop at block 2 (valid terminal block), since block 3 is invalid (past ttd)"

  try:
    skeleton.setHead(block5, false)
  except ErrReorgDenied:
    testCond true
  except:
    testCond false

  testCond env.chainDB.currentBlock == 2.toBlockNumber:
    error "canonical height should not change when setHead is set with force=false"

  # Put correct chain
  skeleton.initSync(block4PoS)
  try:
    discard skeleton.putBlocks([block3PoS])
  except ErrSyncMerged:
    testCond true
  except:
    testCond false

  testCond env.chainDB.currentBlock == 4.toBlockNumber:
    error "canonical height should now be at head with correct chain"

  var header: BlockHeader
  testCond env.chainDB.getBlockHeader(env.chainDB.highestBlock, header):
    error "cannot get block header", number = env.chainDB.highestBlock

  testCond header.blockHash == block4PoS.blockHash:
    error "canonical height should now be at head with correct chain"

  skeleton.setHead(block5, false)
  testCond skeleton.bounds().head == 5.toBlockNumber:
    error "should update to new height"

proc ccmAbortAndBackstep(cc: NetworkParams) =
  cc.config.terminalTotalDifficulty = some(200.u256)
  cc.genesis.extraData = hexToSeqByte("0x000000000000000000")
  cc.genesis.difficulty = UInt256.fromHex("0x01")

proc abortAndBackstep(env: TestEnv): TestStatus =
  result = TestStatus.OK
  env.chain.validateBlock = false
  let skeleton = SkeletonRef.new(env.chain)

  let
    genesisBlock = env.chainDB.getCanonicalHead()
    block1 = BlockHeader(
      blockNumber: 1.toBlockNumber, parentHash: genesisBlock.blockHash, difficulty: 100.u256
    )
    block2 = BlockHeader(
      blockNumber: 2.toBlockNumber, parentHash: block1.blockHash, difficulty: 100.u256
    )
    block3PoW = BlockHeader(
      blockNumber: 3.toBlockNumber, parentHash: block2.blockHash, difficulty: 100.u256
    )
    block4InvalidPoS = BlockHeader(
      blockNumber: 4.toBlockNumber, parentHash: block3PoW.blockHash, difficulty: 0.u256
      #{ common, hardforkByTTD: 200 }
    )

  skeleton.open()
  skeleton.ignoreTxs = true
  skeleton.initSync(block4InvalidPoS)
  discard skeleton.putBlocks([block3PoW, block2])

  testCond env.chainDB.currentBlock == 0.toBlockNumber:
    error "canonical height should be at genesis"

  discard skeleton.putBlocks([block1])
  testCond env.chainDB.currentBlock == 2.toBlockNumber:
    error "canonical height should stop at block 2 (valid terminal block), since block 3 is invalid (past ttd)"

  testCond skeleton.bounds().tail == 4.toBlockNumber:
    error "Subchain should have been backstepped to 4"

proc ccmAbortPOSTooEarly(cc: NetworkParams) =
  cc.config.terminalTotalDifficulty = some(200.u256)
  #skeletonFillCanonicalBackStep: 0,
  cc.genesis.difficulty = UInt256.fromHex("0x01")

proc abortPOSTooEarly(env: TestEnv): TestStatus =
  result = TestStatus.OK
  env.chain.validateBlock = false
  let skeleton = SkeletonRef.new(env.chain)

  let
    genesisBlock = env.chainDB.getCanonicalHead()
    block1 = BlockHeader(
      blockNumber: 1.toBlockNumber, parentHash: genesisBlock.blockHash, difficulty: 100.u256
    )
    block2 = BlockHeader(
      blockNumber: 2.toBlockNumber, parentHash: block1.blockHash, difficulty: 100.u256
    )
    block2PoS = BlockHeader(
      blockNumber: 2.toBlockNumber, parentHash: block1.blockHash, difficulty: 0.u256
    )
    block3 = BlockHeader(
      blockNumber: 3.toBlockNumber, parentHash: block2.blockHash, difficulty: 0.u256
    )

  skeleton.ignoreTxs = true
  skeleton.open()
  skeleton.initSync(block2PoS)
  discard skeleton.putBlocks([block1])

  testCond env.chainDB.currentBlock == 1.toBlockNumber:
    error "canonical height should stop at block 1 (valid PoW block), since block 2 is invalid (invalid PoS, not past ttd)"

  # Put correct chain
  skeleton.initSync(block3)
  try:
    discard skeleton.putBlocks([block2])
  except ErrSyncMerged:
    testCond true
  except:
    testCond false

  testCond env.chainDB.currentBlock == 3.toBlockNumber:
    error "canonical height should now be at head with correct chain"

  var header: BlockHeader
  testCond env.chainDB.getBlockHeader(env.chainDB.highestBlock, header):
    error "cannot get block header", number = env.chainDB.highestBlock

  testCond header.blockHash == block3.blockHash:
    error "canonical height should now be at head with correct chain"

suite "fillCanonicalChain tests":
  type
    TestCase = object
      name: string
      ccm : CCModify
      run : proc(env: TestEnv): TestStatus

  const testCases = [
    TestCase(
      name: "should fill the canonical chain after being linked to genesis",
      run : linkedToGenesis
    ),
    TestCase(
      name: "should fill the canonical chain after being linked to a canonical block past genesis",
      run : linkedPastGenesis
    ),
    TestCase(
      name: "should abort filling the canonical chain if the terminal block is invalid",
      ccm : ccmAbortTerminalInvalid,
      run : abortTerminalInvalid
    ),
    TestCase(
      name: "should abort filling the canonical chain and backstep if the terminal block is invalid",
      ccm : ccmAbortAndBackstep,
      run : abortAndBackstep
    ),
    TestCase(
      name: "should abort filling the canonical chain if a PoS block comes too early without hitting ttd",
      ccm : ccmAbortPOSTooEarly,
      run : abortPOSTooEarly
    )
  ]
  for testCase in testCases:
    test testCase.name:
      let env = initEnv(testCase.ccm)
      check testCase.run(env) == TestStatus.OK
