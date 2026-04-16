# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/[algorithm, sets, times],
  unittest2,
  ../../execution_chain/db/aristo/[
    aristo_check,
    aristo_compute,
    aristo_delete,
    aristo_merge,
    aristo_desc,
    aristo_init/memory_only,
    aristo_tx_frame,
  ]

let samples = [
  # Somew on-the-fly provided stuff
  @[
    # Create leaf node
    (
      hash32"0000000000000000000000000000000000000000000000000000000000000001",
      AristoAccount(balance: 0.u256, codeHash: EMPTY_CODE_HASH),
      hash32"69b5c560f84dde1ecb0584976f4ebbe78e34bb6f32410777309a8693424bb563",
    ),
    # Overwrite existing leaf
    (
      hash32"0000000000000000000000000000000000000000000000000000000000000001",
      AristoAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH),
      hash32"5ce3c539427b494d97d1fc89080118370f173d29c7dec55a292e6c00a08c4465",
    ),
    # Split leaf node with extension
    (
      hash32"0000000000000000000000000000000000000000000000000000000000000002",
      AristoAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH),
      hash32"6f28eee5fe67fba78c5bb42cbf6303574c4139ad97631002e07466d2f98c0d35",
    ),
    (
      hash32"0000000000000000000000000000000000000000000000000000000000000003",
      AristoAccount(balance: 0.u256, codeHash: EMPTY_CODE_HASH),
      hash32"5dacbc38677935c135b911e8c786444e4dc297db1f0c77775ce47ffb8ce81dca",
    ),
    # Split extension
    (
      hash32"0100000000000000000000000000000000000000000000000000000000000000",
      AristoAccount(balance: 1.u256, codeHash: EMPTY_CODE_HASH),
      hash32"57dd53adbbd1969204c0b3435df8c22e0aadadad50871ce7ab4d802b77da2dd3",
    ),
    (
      hash32"0100000000000000000000000000000000000000000000000000000000000001",
      AristoAccount(balance: 2.u256, codeHash: EMPTY_CODE_HASH),
      hash32"67ebbac82cc2a55e0758299f63b785fbd3d1f17197b99c78ffd79d73d3026827",
    ),
    (
      hash32"0200000000000000000000000000000000000000000000000000000000000000",
      AristoAccount(balance: 3.u256, codeHash: EMPTY_CODE_HASH),
      hash32"e7d6a8f7fb3e936eff91a5f62b96177817f2f45a105b729ab54819a99a353325",
    ),
  ]
]

suite "Aristo compute":
  for n, sample in samples:
    test "Add and delete entries " & $n:
      let
        db = AristoDbRef.init()
        txFrame = db.txRef
        root = STATE_ROOT_VID
      db.parallelStateRootComputation = false
      
      for (k, v, r) in sample:
        checkpoint("k = " & k.toHex & ", v = " & $v)

        check:
          txFrame.mergeAccount(k, v) == Result[bool, AristoError].ok(true)

        # Check state against expected value
        let w = txFrame.computeKey((root, root)).expect("no errors")
        check r == w.to(Hash32)

        let rc = txFrame.check
        check rc == typeof(rc).ok()

      # Reverse run deleting entries
      var deletedKeys: HashSet[Hash32]
      for iny, (k, v, r) in sample.reversed:
        # Check whether key was already deleted
        if k in deletedKeys:
          continue
        deletedKeys.incl k

        # Check state against expected value
        let w = txFrame.computeKey((root, root)).value.to(Hash32)

        check r == w

        check:
          txFrame.deleteAccount(k).isOk

        let rc = txFrame.check
        check rc == typeof(rc).ok()

    test "Parallel - add and delete entries " & $n:
      let
        db = AristoDbRef.init()
        txFrame = db.txRef
        root = STATE_ROOT_VID
      db.parallelStateRootComputation = true
      db.taskpool = Taskpool.new(numThreads = 4)
      
      for (k, v, r) in sample:
        checkpoint("k = " & k.toHex & ", v = " & $v)

        check:
          txFrame.mergeAccount(k, v) == Result[bool, AristoError].ok(true)

        # Check state against expected value
        let w = txFrame.computeKey((root, root)).expect("no errors")
        check r == w.to(Hash32)

        let rc = txFrame.check
        check rc == typeof(rc).ok()

      # Reverse run deleting entries
      var deletedKeys: HashSet[Hash32]
      for iny, (k, v, r) in sample.reversed:
        # Check whether key was already deleted
        if k in deletedKeys:
          continue
        deletedKeys.incl k

        # Check state against expected value
        let w = txFrame.computeKey((root, root)).value.to(Hash32)

        check r == w

        check:
          txFrame.deleteAccount(k).isOk

        let rc = txFrame.check
        check rc == typeof(rc).ok()

  test "Pre-computed key":
    # TODO use mainnet genesis in this test?
    let
      db = AristoDbRef.init()
      txFrame = db.txRef
      root = STATE_ROOT_VID
    db.parallelStateRootComputation = false

    for (k, v, r) in samples[^1]:
      check:
        txFrame.mergeAccount(k, v) == Result[bool, AristoError].ok(true)
    txFrame.checkpoint(1, skipSnapshot = true)

    let batch = db.putBegFn()[]
    db.persist(batch, txFrame)
    check db.putEndFn(batch).isOk()

    check txFrame.computeStateRoot(skipLayers = true).isOk()

    let w = txFrame.computeKey((root, root)).value.to(Hash32)
    check w == samples[^1][^1][2]

  test "Parallel - pre-computed key":
    # TODO use mainnet genesis in this test?
    let
      db = AristoDbRef.init()
      txFrame = db.txRef
      root = STATE_ROOT_VID
    db.parallelStateRootComputation = true
    db.taskpool = Taskpool.new(numThreads = 4)

    for (k, v, r) in samples[^1]:
      check:
        txFrame.mergeAccount(k, v) == Result[bool, AristoError].ok(true)
    txFrame.checkpoint(1, skipSnapshot = true)

    let batch = db.putBegFn()[]
    db.persist(batch, txFrame)
    check db.putEndFn(batch).isOk()

    check txFrame.computeStateRoot(skipLayers = true).isOk()

    let w = txFrame.computeKey((root, root)).value.to(Hash32)
    check w == samples[^1][^1][2]
  
  test "Max size RLP encoding of all MPT node types":
    ## This test exercises the RlpArrayBufWriter stack-allocated buffer paths in
    ## aristo_compute.nim by constructing a trie that produces the largest
    ## possible RLP encoding for each MPT node type:
    ##
    ## - Account leaf node (MAX_RLP_SIZE_ACCOUNT_LEAF_NODE = 148):
    ##   Maximised by using max nonce (uint64.high), max balance (UInt256.high),
    ##   a non-empty codeHash, and a valid storageRoot (from attached storage).
    ##
    ## - Storage leaf node (MAX_RLP_SIZE_STORAGE_LEAF_NODE = 70):
    ##   Maximised by storing UInt256.high as the storage value.
    ##
    ## - Branch node (MAX_RLP_SIZE_BRANCH_NODE = 532):
    ##   Maximised by having all 16 child slots occupied at a branch, each with
    ##   a full 32-byte hash key (RLP encoded nodes >= 32 bytes).
    ##
    ## - Extension node (MAX_RLP_SIZE_EXTENSION_NODE = 68):
    ##   Created when multiple paths share a common prefix before diverging,
    ##   producing a hex-prefix-encoded shared nibble path + a branch key child.
    ##
    ## The test inserts enough accounts (with carefully chosen paths) to produce
    ## all four node types, then calls computeKey on the state root to force
    ## RLP serialization through the RlpArrayBufWriter code paths. If any buffer
    ## is undersized the test will fail with an overflow/assertion.

    # Maximum-size account payload: max nonce, max balance, non-empty codeHash.
    # The storageRoot will be filled in by attaching storage to this account.
    let maxAccount = AristoAccount(
      nonce: uint64.high,
      balance: UInt256.high,
      codeHash: hash32"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    )

    # A large account (with storage) to maximise account leaf RLP.
    # This account will also get a storage slot with max value to maximise
    # storage leaf RLP.
    let accPathWithStorage =
      hash32"1000000000000000000000000000000000000000000000000000000000000001"
    check:
      txFrame.mergeAccount(accPathWithStorage, maxAccount) ==
        Result[bool, AristoError].ok(true)

    # Attach a storage slot with the largest possible UInt256 value.
    # This maximises the storage leaf node RLP encoding.
    let
      stoPath = hash32"2000000000000000000000000000000000000000000000000000000000000001"
      maxStoData = UInt256.high
    check:
      txFrame.mergeSlot(accPathWithStorage, stoPath, maxStoData).isOk

    # Insert 16 more accounts at paths chosen so that their keccak hashes
    # spread across all 16 nibble values at the root branch level. This is
    # not guaranteed by arbitrary paths, but inserting enough distinct accounts
    # with varied first nibbles will populate many branch children. We use 16
    # accounts with different leading bytes to maximise the chance of filling
    # the root branch.
    #
    # All use max-size payloads (large nonce, balance, codeHash) to ensure
    # each child's RLP node is >= 32 bytes (so branch stores full 32-byte
    # hash keys rather than inline RLP).
    for i in 0'u8 .. 15'u8:
      var pathBytes: array[32, byte]
      pathBytes[0] = (i * 16) + i  # e.g. 0x00, 0x11, 0x22 ... 0xFF
      pathBytes[1] = 0xFF
      pathBytes[2] = byte(i)
      # Fill remaining bytes to make each path unique
      for j in 3 .. 31:
        pathBytes[j] = byte(i)
      let accPath = Hash32(pathBytes)
      let acc = AristoAccount(
        nonce: uint64.high,
        balance: UInt256.high,
        codeHash: hash32"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      )
      check:
        txFrame.mergeAccount(accPath, acc) == Result[bool, AristoError].ok(true)

    # Insert two more accounts that share a long common prefix to force the
    # creation of an extension node. When two paths share leading nibbles but
    # diverge later, the trie creates an extension node encoding the shared
    # prefix followed by a branch.
    # block:
    let extAcc = AristoAccount(
      nonce: uint64.high,
      balance: UInt256.high,
      codeHash: hash32"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    )
    # These two paths share the first 8 bytes (16 nibbles) then diverge,
    # which should produce an extension node with a long shared prefix.
    let extPath1 =
      hash32"ABCDEF0123456789000000000000000000000000000000000000000000000001"
    let extPath2 =
      hash32"ABCDEF0123456789000000000000000000000000000000000000000000000002"
    
    check txFrame.mergeAccount(extPath1, extAcc) == Result[bool, AristoError].ok(true)
    check txFrame.mergeAccount(extPath2, extAcc) == Result[bool, AristoError].ok(true)

    # Now compute the state root key. This forces RLP serialization of every
    # node in the trie through the RlpArrayBufWriter code paths.
    # If any ArrayBuf is too small, this will fail with an assertion/overflow.
    let stateRoot = txFrame.computeKey((root, root))
    check stateRoot.isOk

    # Verify the root hash is a valid 32-byte hash
    let rootHash = stateRoot.value.to(Hash32)
    check rootHash != default(Hash32)

    # Run structural integrity checks on the trie
    let rc = txFrame.check
    check rc == typeof(rc).ok()

    # Verify the computation is stable (computing again gives the same result)
    let stateRoot2 = txFrame.computeKey((root, root))
    check stateRoot2.isOk
    check stateRoot2.value == stateRoot.value


suite "Aristo compute short benchmark":
  const 
    NUM_THREADS = 4
    NUM_FRAMES = 1000
    NUM_ACCOUNTS_PER_FRAME = 100

  setup:
    let db = AristoDbRef.init()
    var txFrame = db.txRef
    db.taskpool = Taskpool.new(numThreads = NUM_THREADS)


    for i in 0 ..< NUM_ACCOUNTS_PER_FRAME:
      check:
        txFrame.mergeAccount(
          cast[Hash32](i), 
          AristoAccount(balance: i.u256(), codeHash: EMPTY_CODE_HASH)) == Result[bool, AristoError].ok(true)
    txFrame.checkpoint(1, skipSnapshot = true)

    let batch = db.putBegFn()[]
    db.persist(batch, txFrame)
    check db.putEndFn(batch).isOk()
    
    txFrame = db.baseTxFrame()
    
    for n in 1 .. NUM_FRAMES:
      txFrame = db.txFrameBegin(txFrame)

      let 
        startIdx = NUM_ACCOUNTS_PER_FRAME * n
        endIdx = startIdx + NUM_ACCOUNTS_PER_FRAME

      for i in startIdx ..< endIdx:
        check:
          txFrame.mergeAccount(
            cast[Hash32](i * i), 
            AristoAccount(balance: i.u256(), codeHash: EMPTY_CODE_HASH)) == Result[bool, AristoError].ok(true)
      
      txFrame.checkpoint(1, skipSnapshot = false)

  test "Serial benchmark - skipLayers = false":
    db.parallelStateRootComputation = false
    debugEcho "\nSerial benchmark (skipLayers = false) running..."

    let before = cpuTime()
    check txFrame.computeStateRoot(skipLayers = false).isOk()
    let elapsed = cpuTime() - before
    
    debugEcho "Serial benchmark (skipLayers = false) cpu time: ", elapsed

  test "Parallel benchmark - skipLayers = false":
    db.parallelStateRootComputation = true
    debugEcho "\nParallel benchmark (skipLayers = false) running..."

    let before = cpuTime()
    check txFrame.computeStateRoot(skipLayers = false).isOk()
    let elapsed = cpuTime() - before
    
    debugEcho "Parallel benchmark (skipLayers = false) cpu time: ", elapsed