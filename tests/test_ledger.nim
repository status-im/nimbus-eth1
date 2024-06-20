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
  std/[strformat, strutils],
  eth/keys,
  stew/byteutils,
  stew/endians2,
  ../nimbus/config,
  ../nimbus/db/ledger,
  ../nimbus/common/common,
  ../nimbus/core/chain,
  ../nimbus/core/tx_pool,
  ../nimbus/core/casper,
  ../nimbus/transaction,
  ../nimbus/constants,
  unittest2

const
  genesisFile = "tests/customgenesis/cancun123.json"
  hexPrivKey  = "af1a9be9f1a54421cac82943820a0fe0f601bb5f4f6d0bccc81c613f0ce6ae22"
  senderAddr  = hexToByteArray[20]("73cf19657412508833f618a15e8251306b3e6ee5")

type
  TestEnv = object
    com: CommonRef
    xdb: CoreDbRef
    txs: seq[Transaction]
    txi: seq[int] # selected index into txs[] (crashable sender addresses)
    vaultKey: PrivateKey
    nonce   : uint64
    chainId : ChainId
    xp      : TxPoolRef
    chain   : ChainRef

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc pp*(a: EthAddress): string =
  a.toHex[32 .. 39].toLowerAscii

proc pp*(tx: Transaction): string =
  # "(" & tx.ecRecover.value.pp & "," & $tx.nonce & ")"
  "(" & tx.getSender.pp & "," & $tx.nonce & ")"

proc pp*(h: KeccakHash): string =
  h.data.toHex[52 .. 63].toLowerAscii

proc pp*(tx: Transaction; ledger: LedgerRef): string =
  let address = tx.getSender
  "(" & address.pp &
    "," & $tx.nonce &
    ";" & $ledger.getNonce(address) &
    "," & $ledger.getBalance(address) &
    ")"

when isMainModule:
  import chronicles
  
  proc setTraceLevel =
    discard
    when defined(chronicles_runtime_filtering) and loggingEnabled:
      setLogLevel(LogLevel.TRACE)

  proc setErrorLevel =
    discard
    when defined(chronicles_runtime_filtering) and loggingEnabled:
      setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------
proc privKey(keyHex: string): PrivateKey =
  let kRes = PrivateKey.fromHex(keyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  kRes.get()

proc initEnv(): TestEnv =
  let
    conf = makeConfig(@[
      "--custom-network:" & genesisFile
    ])

  let
    com = CommonRef.new(
      newCoreDbRef DefaultDbMemory,
      conf.networkId,
      conf.networkParams
    )
  com.initializeEmptyDb()

  TestEnv(
    com     : com,
    xdb     : com.db,
    vaultKey: privKey(hexPrivKey),
    nonce   : 0'u64,
    chainId : conf.networkParams.config.chainId,
    xp      : TxPoolRef.new(com),
    chain   : newChain(com),
  )

func makeTx(
    env: var TestEnv,
    recipient: EthAddress,
    amount: UInt256,
    payload: openArray[byte] = []): Transaction =
  const
    gasLimit = 75000.GasInt
    gasPrice = 30.gwei

  let tx = Transaction(
    txType  : TxLegacy,
    chainId : env.chainId,
    nonce   : AccountNonce(env.nonce),
    gasPrice: gasPrice,
    gasLimit: gasLimit,
    to      : Opt.some(recipient),
    value   : amount,
    payload : @payload
  )

  inc env.nonce
  signTransaction(tx, env.vaultKey, env.chainId, eip155 = true)

func initAddr(z: int): EthAddress =
  const L = sizeof(result)
  result[L-sizeof(uint32)..^1] = toBytesBE(z.uint32)

proc importBlocks(env: TestEnv; blk: EthBlock) =
  let res = env.chain.persistBlocks([blk])
  if res.isErr:
    debugEcho res.error
    raiseAssert "persistBlocks() failed at block #" & $blk.header.number

proc getLedger(com: CommonRef; header: BlockHeader): LedgerRef =
  LedgerRef.init(com.db, header.stateRoot)

func getRecipient(tx: Transaction): EthAddress =
  tx.to.expect("transaction have no recipient")

# ------------------------------------------------------------------------------
# Crash test function, finding out about how the transaction framework works ..
# ------------------------------------------------------------------------------

proc modBalance(ac: LedgerRef, address: EthAddress) =
  ## This function is crucial for profucing the crash. If must
  ## modify the balance so that the database gets written.
  # ac.blindBalanceSetter(address)
  ac.addBalance(address, 1.u256)


proc runTrial2ok(env: TestEnv, ledger: LedgerRef; inx: int) =
  ## Run two blocks, the first one with *rollback*.
  let eAddr = env.txs[inx].getRecipient

  block:
    let accTx = ledger.beginSavepoint
    ledger.modBalance(eAddr)
    ledger.rollback(accTx)

  block:
    let accTx = ledger.beginSavepoint
    ledger.modBalance(eAddr)
    ledger.commit(accTx)

  ledger.persist()


proc runTrial3(env: TestEnv, ledger: LedgerRef; inx: int; rollback: bool) =
  ## Run three blocks, the second one optionally with *rollback*.
  let eAddr = env.txs[inx].getRecipient

  block body1:
    let accTx = ledger.beginSavepoint
    ledger.modBalance(eAddr)
    ledger.commit(accTx)
    ledger.persist()

  block body2:
    let accTx = ledger.beginSavepoint
    ledger.modBalance(eAddr)

    if rollback:
      ledger.rollback(accTx)
      break body2

    ledger.commit(accTx)
    ledger.persist()

  block body3:
    let accTx = ledger.beginSavepoint
    ledger.modBalance(eAddr)
    ledger.commit(accTx)
    ledger.persist()


proc runTrial3Survive(env: TestEnv, ledger: LedgerRef; inx: int; noisy = false) =
  ## Run three blocks with extra db frames and *rollback*.
  let eAddr = env.txs[inx].getRecipient

  block:
    let dbTx = env.xdb.newTransaction()

    block:
      let accTx = ledger.beginSavepoint
      ledger.modBalance(eAddr)
      ledger.commit(accTx)
      ledger.persist()

    block:
      let accTx = ledger.beginSavepoint
      ledger.modBalance(eAddr)
      ledger.rollback(accTx)

    dbTx.rollback()

  block:
    let dbTx = env.xdb.newTransaction()

    block:
      let accTx = ledger.beginSavepoint
      ledger.modBalance(eAddr)
      ledger.commit(accTx)

      ledger.persist()

      ledger.persist()

    dbTx.commit()


proc runTrial4(env: TestEnv, ledger: LedgerRef; inx: int; rollback: bool) =
  ## Like `runTrial3()` but with four blocks and extra db transaction frames.
  let eAddr = env.txs[inx].getRecipient

  block:
    let dbTx = env.xdb.newTransaction()

    block:
      let accTx = ledger.beginSavepoint
      ledger.modBalance(eAddr)
      ledger.commit(accTx)
      ledger.persist()

    block:
      let accTx = ledger.beginSavepoint
      ledger.modBalance(eAddr)
      ledger.commit(accTx)
      ledger.persist()

    block:
      let accTx = ledger.beginSavepoint
      ledger.modBalance(eAddr)

      if rollback:
        ledger.rollback(accTx)
        break

      ledger.commit(accTx)
      ledger.persist()

    # There must be no dbTx.rollback() here unless `ledger` is
    # discarded and/or re-initialised.
    dbTx.commit()

  block:
    let dbTx = env.xdb.newTransaction()

    block:
      let accTx = ledger.beginSavepoint
      ledger.modBalance(eAddr)
      ledger.commit(accTx)
      ledger.persist()

    dbTx.commit()

# ------------------------------------------------------------------------------
# Test Runner
# ------------------------------------------------------------------------------

const
  NumTransactions = 17
  NumBlocks = 13
  feeRecipient = initAddr(401)
  prevRandao = EMPTY_UNCLE_HASH # it can be any valid hash

proc runner(noisy = true) =
  suite "StateDB nesting scenarios":
    var env = initEnv()

    test "Create transactions and blocks":
      var
        recipientSeed = 501
        blockTime = EthTime.now()

      for _ in 0..<NumBlocks:
        for _ in 0..<NumTransactions:
          let recipient = initAddr(recipientSeed)
          let tx = env.makeTx(recipient, 1.u256)
          let res = env.xp.addLocal(PooledTransaction(tx: tx), force = true)
          check res.isOk
          if res.isErr:
            debugEcho res.error
            return

          inc recipientSeed

        check env.xp.nItems.total == NumTransactions
        env.com.pos.prevRandao = prevRandao
        env.com.pos.feeRecipient = feeRecipient
        env.com.pos.timestamp = blockTime

        blockTime = EthTime(blockTime.uint64 + 1'u64)

        let r = env.xp.assembleBlock()
        if r.isErr:
          debugEcho r.error
          check false
          return

        let blk = r.get.blk
        let body = BlockBody(
          transactions: blk.txs,
          uncles: blk.uncles,
          withdrawals: Opt.some(newSeq[Withdrawal]())
        )
        env.importBlocks(EthBlock.init(blk.header, body))

        check env.xp.smartHead(blk.header)
        for tx in body.transactions:
          env.txs.add tx

    test &"Collect unique recipient addresses from {env.txs.len} txs," &
        &" head=#{env.xdb.getCanonicalHead.number}":
      # since we generate our own transactions instead of replaying
      # from testnet blocks, the recipients already unique.
      for n,tx in env.txs:
        #let a = tx.getRecipient
        env.txi.add n

    test &"Run {env.txi.len} two-step trials with rollback":
      let head = env.xdb.getCanonicalHead()
      for n in env.txi:
        let dbTx = env.xdb.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger(head)
        env.runTrial2ok(ledger, n)

    test &"Run {env.txi.len} three-step trials with rollback":
      let head = env.xdb.getCanonicalHead()
      for n in env.txi:
        let dbTx = env.xdb.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger(head)
        env.runTrial3(ledger, n, rollback = true)

    test &"Run {env.txi.len} three-step trials with extra db frame rollback" &
        " throwing Exceptions":
      let head = env.xdb.getCanonicalHead()
      for n in env.txi:
        let dbTx = env.xdb.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger(head)
        env.runTrial3Survive(ledger, n, noisy)

    test &"Run {env.txi.len} tree-step trials without rollback":
      let head = env.xdb.getCanonicalHead()
      for n in env.txi:
        let dbTx = env.xdb.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger(head)
        env.runTrial3(ledger, n, rollback = false)

    test &"Run {env.txi.len} four-step trials with rollback and db frames":
      let head = env.xdb.getCanonicalHead()
      for n in env.txi:
        let dbTx = env.xdb.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger(head)
        env.runTrial4(ledger, n, rollback = true)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc ledgerMain*(noisy = defined(debug)) =
  noisy.runner

when isMainModule:
  var noisy = defined(debug)

  setErrorLevel()
  noisy.runner

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
