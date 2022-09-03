import
  std/[strutils, math, tables, options, times],
  eth/[trie/db, keys, common, trie/hexary],
  stew/[byteutils, results], unittest2,
  ../nimbus/db/[db_chain, state_db],
  ../nimbus/p2p/chain,
  ../nimbus/p2p/clique/[clique_sealer, clique_desc],
  ../nimbus/[chain_config, config, genesis, transaction, constants],
  ../nimbus/utils/tx_pool,
  ./test_txpool/helpers,
  ./macro_assembler

const
  baseDir = [".", "tests"]
  repoDir = [".", "customgenesis"]
  genesisFile = "merge.json"

type
  TestEnv = object
    nonce   : uint64
    chainId : ChainId
    vaultKey: PrivateKey
    conf    : NimbusConf
    chainDB : BaseChainDB
    chain   : Chain
    xp      : TxPoolRef

const
  signerKeyHex = "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
  vaultKeyHex = "63b508a03c3b5937ceb903af8b1b0c191012ef6eb7e9c3fb7afa94e5d214d376"
  recipient = hexToByteArray[20]("0000000000000000000000000000000000000318")
  feeRecipient = hexToByteArray[20]("0000000000000000000000000000000000000212")
  contractCode = evmByteCode:
    PrevRandao    # VAL
    Push1 "0x11"  # KEY
    Sstore        # OP
    Stop

proc privKey(keyHex: string): PrivateKey =
  let kRes = PrivateKey.fromHex(keyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  kRes.get()

func gwei(n: uint64): GasInt {.compileTime.} =
  GasInt(n * (10'u64 ^ 9'u64))

proc makeTx*(t: var TestEnv, recipient: EthAddress, amount: UInt256, payload: openArray[byte] = []): Transaction =
  const
    gasLimit = 75000.GasInt
    gasPrice = 30.gwei

  let tx = Transaction(
    txType  : TxLegacy,
    chainId : t.chainId,
    nonce   : AccountNonce(t.nonce),
    gasPrice: gasPrice,
    gasLimit: gasLimit,
    to      : some(recipient),
    value   : amount,
    payload : @payload
  )

  inc t.nonce
  signTransaction(tx, t.vaultKey, t.chainId, eip155 = true)

proc initEnv(ttd: Option[UInt256] = none(UInt256)): TestEnv =
  var
    conf = makeConfig(@[
      "--engine-signer:658bdf435d810c91414ec09147daa6db62406379",
      "--custom-network:" & genesisFile.findFilePath(baseDir,repoDir).value
    ])

  conf.networkParams.genesis.alloc[recipient] = GenesisAccount(
    code: contractCode
  )

  if ttd.isSome:
    conf.networkParams.config.terminalTotalDifficulty = ttd

  let
    chainDB = newBaseChainDB(
      newMemoryDb(),
      conf.pruneMode == PruneMode.Full,
      conf.networkId,
      conf.networkParams
    )
    chain = newChain(chainDB)

  initializeEmptyDb(chainDB)

  result = TestEnv(
    conf: conf,
    chainDB: chainDB,
    chain: chain,
    xp: TxPoolRef.new(chainDB, conf.engineSigner),
    vaultKey: privKey(vaultKeyHex),
    chainId: conf.networkParams.config.chainId,
    nonce: 0'u64
  )

const
  amount = 1000.u256
  slot = 0x11.u256
  prevRandao = EMPTY_UNCLE_HASH # it can be any valid hash

proc runTxPoolCliqueTest*() =
  var
    env = initEnv()

  var
    tx = env.makeTx(recipient, amount)
    xp = env.xp
    conf = env.conf
    chainDB = env.chainDB
    chain = env.chain
    clique = env.chain.clique
    body: BlockBody
    blk: EthBlock

  let signerKey = privKey(signerKeyHex)
  proc signerFunc(signer: EthAddress, msg: openArray[byte]):
                  Result[RawSignature, cstring] {.gcsafe.} =
    doAssert(signer == conf.engineSigner)
    let
      data = keccakHash(msg)
      rawSign  = sign(signerKey, SkMessage(data.data)).toRaw

    ok(rawSign)

  suite "Test TxPool with Clique sealer":
    test "TxPool addLocal":
      let res = xp.addLocal(tx, force = true)
      check res.isOk
      if res.isErr:
        debugEcho res.error
        return

    test "TxPool jobCommit":
      check xp.nItems.total == 1

    test "TxPool ethBlock":
      xp.prevRandao = EMPTY_UNCLE_HASH
      blk = xp.ethBlock()

      blk.header.prevRandao = EMPTY_UNCLE_HASH
      body = BlockBody(
        transactions: blk.txs,
        uncles: blk.uncles
      )
      check blk.txs.len == 1

    test "Clique prepare and seal":
      clique.authorize(conf.engineSigner, signerFunc)
      let parent = chainDB.getBlockHeader(blk.header.parentHash)
      let ry = chain.clique.prepare(parent, blk.header)
      check ry.isOk
      if ry.isErr:
        debugEcho ry.error
        return

      let rx = clique.seal(blk)
      check rx.isOk
      if rx.isErr:
        debugEcho rx.error
        return

    test "Clique persistBlocks":
      let rr = chain.persistBlocks([blk.header], [body])
      check rr == ValidationResult.OK

proc runTxPoolPosTest*() =
  var
    env = initEnv(some(100.u256))

  var
    tx = env.makeTx(recipient, amount)
    xp = env.xp
    chainDB = env.chainDB
    chain = env.chain
    body: BlockBody
    blk: EthBlock

  suite "Test TxPool with PoS block":
    test "TxPool addLocal":
      let res = xp.addLocal(tx, force = true)
      check res.isOk
      if res.isErr:
        debugEcho res.error
        return

    test "TxPool jobCommit":
      check xp.nItems.total == 1

    test "TxPool ethBlock":
      xp.prevRandao = prevRandao
      xp.feeRecipient = feeRecipient
      blk = xp.ethBlock()

      check chain.isBlockAfterTtd(blk.header)

      blk.header.difficulty = DifficultyInt.zero
      blk.header.prevRandao = prevRandao
      blk.header.nonce = default(BlockNonce)
      blk.header.extraData = @[]

      body = BlockBody(
        transactions: blk.txs,
        uncles: blk.uncles
      )
      check blk.txs.len == 1

    test "PoS persistBlocks":
      let rr = chain.persistBlocks([blk.header], [body])
      check rr == ValidationResult.OK

    test "validate TxPool prevRandao setter":
      var sdb = newAccountStateDB(chainDB.db, blk.header.stateRoot, pruneTrie = false)
      let (val, ok) = sdb.getStorage(recipient, slot)
      let randao = Hash256(data: val.toBytesBE)
      check ok
      check randao == prevRandao

    test "feeRecipient rewarded":
      check blk.header.coinbase == feeRecipient
      var sdb = newAccountStateDB(chainDB.db, blk.header.stateRoot, pruneTrie = false)
      let bal = sdb.getBalance(feeRecipient)
      check not bal.isZero

#runTxPoolPosTest()


proc runTxHeadDelta*(noisy = true) =
  ## see github.com/status-im/nimbus-eth1/issues/1031

  suite "TxPool: Synthesising blocks (covers issue #1031)":
    test "Packing and adding multiple blocks to chain":
      var
        env = initEnv(some(100.u256))
        xp = env.xp
        chainDB = env.chainDB
        chain = env.chain
        head = chainDB.getCanonicalHead()
        timestamp = head.timestamp

      const
        txPerblock = 20
        numBlocks = 10

      # setTraceLevel()

      block:
        for n in 0..<numBlocks:

          for tn in 0..<txPerblock:
            let tx = env.makeTx(recipient, amount)
            # Instead of `add()`, the functions `addRemote()` or `addLocal()`
            # also would do.
            xp.add(tx)

          noisy.say "***", "txDB",
            &" n={n}",
            # pending/staged/packed : total/disposed
            &" stats={xp.nItems.pp}"

          xp.prevRandao = prevRandao
          var blk = xp.ethBlock()
          check chain.isBlockAfterTtd(blk.header)

          timestamp = timestamp + 1.seconds
          blk.header.difficulty = DifficultyInt.zero
          blk.header.prevRandao = prevRandao
          blk.header.nonce = default(BlockNonce)
          blk.header.extraData = @[]
          blk.header.timestamp = timestamp

          let body = BlockBody(
            transactions: blk.txs,
            uncles: blk.uncles)

          # Commit to block chain
          check chain.persistBlocks([blk.header], [body]).isOk

          # If not for other reason, setting head is irrelevant for this test
          #
          # # PoS block canonical head must be explicitly set using setHead.
          # # The function `persistHeaderToDb()` used in `persistBlocks()`
          # # does not reliably do so due to scoring.
          # chainDB.setHead(blk.header)

          # Synchronise TxPool against new chain head, register txs differences.
          # In this particular case, these differences will simply flush the
          # packer bucket.
          check xp.smartHead(blk.header)

          # Move TxPool chain head to new chain head and apply delta jobs
          check xp.nItems.staged == 0
          check xp.nItems.packed == 0

          setErrorLevel() # in case we set trace level

      check chainDB.currentBlock == 10.toBlockNumber
      head = chainDB.getBlockHeader(chainDB.currentBlock)
      var
        sdb = newAccountStateDB(chainDB.db, head.stateRoot, pruneTrie = false)

      let
        expected = u256(txPerblock * numBlocks) * amount
        balance = sdb.getBalance(recipient)
      check balance == expected

when isMainModule:
  const
    noisy = defined(debug)

  setErrorLevel() # mute logger

  runTxPoolCliqueTest()
  runTxPoolPosTest()
  noisy.runTxHeadDelta

# End
