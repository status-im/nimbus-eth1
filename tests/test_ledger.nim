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
  std/[strformat, strutils, importutils],
  eth/common/[keys, transaction_utils],
  stew/byteutils,
  stew/endians2,
  ../nimbus/config,
  ../nimbus/db/storage_types,
  ../nimbus/common/common,
  ../nimbus/core/chain,
  ../nimbus/core/tx_pool,
  ../nimbus/core/casper,
  ../nimbus/transaction,
  ../nimbus/constants,
  ../nimbus/db/ledger {.all.}, # import all private symbols
  unittest2

const
  genesisFile = "tests/customgenesis/cancun123.json"
  hexPrivKey  = "af1a9be9f1a54421cac82943820a0fe0f601bb5f4f6d0bccc81c613f0ce6ae22"

# The above privKey will generate this address
# senderAddr  = hexToByteArray[20]("73cf19657412508833f618a15e8251306b3e6ee5")

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
    chain   : ForkedChainRef

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc pp*(a: Address): string =
  a.toHex[32 .. 39].toLowerAscii

proc pp*(tx: Transaction): string =
  # "(" & tx.ecRecover.value.pp & "," & $tx.nonce & ")"
  "(" & tx.recoverSender().value().pp & "," & $tx.nonce & ")"

proc pp*(h: Hash32): string =
  h.data.toHex[52 .. 63].toLowerAscii

proc pp*(tx: Transaction; ledger: LedgerRef): string =
  let address = tx.recoverSender().value()
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
      newCoreDbRef DefaultDbMemory, nil,
      conf.networkId,
      conf.networkParams
    )

  TestEnv(
    com     : com,
    xdb     : com.db,
    vaultKey: privKey(hexPrivKey),
    nonce   : 0'u64,
    chainId : conf.networkParams.config.chainId,
    xp      : TxPoolRef.new(com),
    chain   : newForkedChain(com, com.genesisHeader),
  )

func makeTx(
    env: var TestEnv,
    recipient: Address,
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
  signTransaction(tx, env.vaultKey, eip155 = true)

func initAddr(z: int): Address =
  const L = sizeof(result)
  result.data[L-sizeof(uint32)..^1] = toBytesBE(z.uint32)

proc importBlock(env: TestEnv; blk: Block) =
  env.chain.importBlock(blk).isOkOr:
    raiseAssert "persistBlocks() failed at block #" &
      $blk.header.number & " msg: " & error

proc getLedger(com: CommonRef): LedgerRef =
  LedgerRef.init(com.db)

func getRecipient(tx: Transaction): Address =
  tx.to.expect("transaction have no recipient")

# ------------------------------------------------------------------------------
# Crash test function, finding out about how the transaction framework works ..
# ------------------------------------------------------------------------------

proc modBalance(ac: LedgerRef, address: Address) =
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

  block:
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

  block:
    let accTx = ledger.beginSavepoint
    ledger.modBalance(eAddr)
    ledger.commit(accTx)
    ledger.persist()


proc runTrial3Survive(env: TestEnv, ledger: LedgerRef; inx: int; noisy = false) =
  ## Run three blocks with extra db frames and *rollback*.
  let eAddr = env.txs[inx].getRecipient

  block:
    let dbTx = env.xdb.ctx.newTransaction()

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
    let dbTx = env.xdb.ctx.newTransaction()

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
    let dbTx = env.xdb.ctx.newTransaction()

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

    block body3:
      let accTx = ledger.beginSavepoint
      ledger.modBalance(eAddr)

      if rollback:
        ledger.rollback(accTx)
        break body3

      ledger.commit(accTx)
      ledger.persist()

    # There must be no dbTx.rollback() here unless `ledger` is
    # discarded and/or re-initialised.
    dbTx.commit()

  block:
    let dbTx = env.xdb.ctx.newTransaction()

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
  prevRandao = Bytes32 EMPTY_UNCLE_HASH # it can be any valid hash

proc runLedgerTransactionTests(noisy = true) =
  suite "Ledger nesting scenarios":
    var env = initEnv()

    test "Create transactions and blocks":
      var
        recipientSeed = 501
        blockTime = EthTime.now()

      for _ in 0..<NumBlocks:
        for _ in 0..<NumTransactions:
          let recipient = initAddr(recipientSeed)
          let tx = env.makeTx(recipient, 1.u256)
          env.xp.add(PooledTransaction(tx: tx))

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
        env.importBlock(Block.init(blk.header, body))

        check env.xp.smartHead(blk.header, env.chain)
        for tx in body.transactions:
          env.txs.add tx

    let head = env.xdb.getCanonicalHead().expect("canonicalHead exists")
    test &"Collect unique recipient addresses from {env.txs.len} txs," &
        &" head=#{head.number}":
      # since we generate our own transactions instead of replaying
      # from testnet blocks, the recipients already unique.
      for n,tx in env.txs:
        #let a = tx.getRecipient
        env.txi.add n

    test &"Run {env.txi.len} two-step trials with rollback":
      for n in env.txi:
        let dbTx = env.xdb.ctx.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger()
        env.runTrial2ok(ledger, n)

    test &"Run {env.txi.len} three-step trials with rollback":
      for n in env.txi:
        let dbTx = env.xdb.ctx.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger()
        env.runTrial3(ledger, n, rollback = true)

    test &"Run {env.txi.len} three-step trials with extra db frame rollback" &
        " throwing Exceptions":
      for n in env.txi:
        let dbTx = env.xdb.ctx.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger()
        env.runTrial3Survive(ledger, n, noisy)

    test &"Run {env.txi.len} tree-step trials without rollback":
      for n in env.txi:
        let dbTx = env.xdb.ctx.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger()
        env.runTrial3(ledger, n, rollback = false)

    test &"Run {env.txi.len} four-step trials with rollback and db frames":
      for n in env.txi:
        let dbTx = env.xdb.ctx.newTransaction()
        defer: dbTx.dispose()
        let ledger = env.com.getLedger()
        env.runTrial4(ledger, n, rollback = true)

proc runLedgerBasicOperationsTests() =
  suite "Ledger basic operations tests":
    setup:
      const emptyAcc {.used.} = Account.init()

      var
        memDB = newCoreDbRef DefaultDbMemory
        stateDB {.used.} = LedgerRef.init(memDB)
        address {.used.} = address"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6"
        code {.used.} = hexToSeqByte("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
        stateRoot {.used.} : Hash32

    test "accountExists and isDeadAccount":
      check stateDB.accountExists(address) == false
      check stateDB.isDeadAccount(address) == true

      stateDB.setBalance(address, 1000.u256)

      check stateDB.accountExists(address) == true
      check stateDB.isDeadAccount(address) == false

      stateDB.setBalance(address, 0.u256)
      stateDB.setNonce(address, 1)
      check stateDB.isDeadAccount(address) == false

      stateDB.setCode(address, code)
      stateDB.setNonce(address, 0)
      check stateDB.isDeadAccount(address) == false

      stateDB.setCode(address, newSeq[byte]())
      check stateDB.isDeadAccount(address) == true
      check stateDB.accountExists(address) == true

    test "clone storage":
      # give access to private fields of AccountRef
      privateAccess(AccountRef)
      var x = AccountRef(
        overlayStorage: Table[UInt256, UInt256](),
        originalStorage: newTable[UInt256, UInt256]()
      )

      x.overlayStorage[10.u256] = 11.u256
      x.overlayStorage[11.u256] = 12.u256

      x.originalStorage[10.u256] = 11.u256
      x.originalStorage[11.u256] = 12.u256

      var y = x.clone(cloneStorage = true)
      y.overlayStorage[12.u256] = 13.u256
      y.originalStorage[12.u256] = 13.u256

      check 12.u256 notin x.overlayStorage
      check 12.u256 in y.overlayStorage

      check x.overlayStorage.len == 2
      check y.overlayStorage.len == 3

      check 12.u256 in x.originalStorage
      check 12.u256 in y.originalStorage

      check x.originalStorage.len == 3
      check y.originalStorage.len == 3

    test "Ledger various operations":
      var ac = LedgerRef.init(memDB)
      var addr1 = initAddr(1)

      check ac.isDeadAccount(addr1) == true
      check ac.accountExists(addr1) == false
      check ac.contractCollision(addr1) == false

      ac.setBalance(addr1, 1000.u256)
      check ac.getBalance(addr1) == 1000.u256
      ac.subBalance(addr1, 100.u256)
      check ac.getBalance(addr1) == 900.u256
      ac.addBalance(addr1, 200.u256)
      check ac.getBalance(addr1) == 1100.u256

      ac.setNonce(addr1, 1)
      check ac.getNonce(addr1) == 1
      ac.incNonce(addr1)
      check ac.getNonce(addr1) == 2

      ac.setCode(addr1, code)
      check ac.getCode(addr1) == code

      ac.setStorage(addr1, 1.u256, 10.u256)
      check ac.getStorage(addr1, 1.u256) == 10.u256
      check ac.getCommittedStorage(addr1, 1.u256) == 0.u256

      check ac.contractCollision(addr1) == true
      check ac.getCodeSize(addr1) == code.len

      ac.persist()
      stateRoot = ac.getStateRoot()

      var db = LedgerRef.init(memDB)
      db.setBalance(addr1, 1100.u256)
      db.setNonce(addr1, 2)
      db.setCode(addr1, code)
      db.setStorage(addr1, 1.u256, 10.u256)
      check stateRoot == db.getStateRoot()

      # Ledger readonly operations using previous hash
      var ac2 = LedgerRef.init(memDB)
      var addr2 = initAddr(2)

      check ac2.getCodeHash(addr2) == emptyAcc.codeHash
      check ac2.getBalance(addr2) == emptyAcc.balance
      check ac2.getNonce(addr2) == emptyAcc.nonce
      check ac2.getCode(addr2) == []
      check ac2.getCodeSize(addr2) == 0
      check ac2.getCommittedStorage(addr2, 1.u256) == 0.u256
      check ac2.getStorage(addr2, 1.u256) == 0.u256
      check ac2.contractCollision(addr2) == false
      check ac2.accountExists(addr2) == false
      check ac2.isDeadAccount(addr2) == true

      ac2.persist()
      # readonly operations should not modify
      # state trie at all
      check ac2.getStateRoot() == stateRoot

    test "Ledger code retrieval after persist called":
      var ac = LedgerRef.init(memDB)
      var addr2 = initAddr(2)
      ac.setCode(addr2, code)
      ac.persist()
      check ac.getCode(addr2) == code
      let
        key = contractHashKey(keccak256(code))
        val = memDB.ctx.getKvt().get(key.toOpenArray).valueOr: EmptyBlob
      check val == code

    test "accessList operations":
      proc verifyAddrs(ac: LedgerRef, addrs: varargs[int]): bool =
        for c in addrs:
          if not ac.inAccessList(c.initAddr):
            return false
        true

      proc verifySlots(ac: LedgerRef, address: int, slots: varargs[int]): bool =
        let a = address.initAddr
        if not ac.inAccessList(a):
            return false

        for c in slots:
          if not ac.inAccessList(a, c.u256):
            return false
        true

      proc accessList(ac: LedgerRef, address: int) {.inline.} =
        ac.accessList(address.initAddr)

      proc accessList(ac: LedgerRef, address, slot: int) {.inline.} =
        ac.accessList(address.initAddr, slot.u256)

      var ac = LedgerRef.init(memDB)

      ac.accessList(0xaa)
      ac.accessList(0xbb, 0x01)
      ac.accessList(0xbb, 0x02)
      check ac.verifyAddrs(0xaa, 0xbb)
      check ac.verifySlots(0xbb, 0x01, 0x02)
      check ac.verifySlots(0xaa, 0x01) == false
      check ac.verifySlots(0xaa, 0x02) == false

      var sp = ac.beginSavepoint
      # some new ones
      ac.accessList(0xbb, 0x03)
      ac.accessList(0xaa, 0x01)
      ac.accessList(0xcc, 0x01)
      ac.accessList(0xcc)

      check ac.verifyAddrs(0xaa, 0xbb, 0xcc)
      check ac.verifySlots(0xaa, 0x01)
      check ac.verifySlots(0xbb, 0x01, 0x02, 0x03)
      check ac.verifySlots(0xcc, 0x01)

      ac.rollback(sp)
      check ac.verifyAddrs(0xaa, 0xbb)
      check ac.verifyAddrs(0xcc) == false
      check ac.verifySlots(0xcc, 0x01) == false

      sp = ac.beginSavepoint
      ac.accessList(0xbb, 0x03)
      ac.accessList(0xaa, 0x01)
      ac.accessList(0xcc, 0x01)
      ac.accessList(0xcc)
      ac.accessList(0xdd, 0x04)
      ac.commit(sp)

      check ac.verifyAddrs(0xaa, 0xbb, 0xcc)
      check ac.verifySlots(0xaa, 0x01)
      check ac.verifySlots(0xbb, 0x01, 0x02, 0x03)
      check ac.verifySlots(0xcc, 0x01)
      check ac.verifySlots(0xdd, 0x04)

    test "transient storage operations":
      var ac = LedgerRef.init(memDB)

      proc tStore(ac: LedgerRef, address, slot, val: int) =
        ac.setTransientStorage(address.initAddr, slot.u256, val.u256)

      proc tLoad(ac: LedgerRef, address, slot: int): UInt256 =
        ac.getTransientStorage(address.initAddr, slot.u256)

      proc vts(ac: LedgerRef, address, slot, val: int): bool =
        ac.tLoad(address, slot) == val.u256

      ac.tStore(0xaa, 3, 66)
      ac.tStore(0xbb, 1, 33)
      ac.tStore(0xbb, 2, 99)

      check ac.vts(0xaa, 3, 66)
      check ac.vts(0xbb, 1, 33)
      check ac.vts(0xbb, 2, 99)
      check ac.vts(0xaa, 1, 33) == false
      check ac.vts(0xbb, 1, 66) == false

      var sp = ac.beginSavepoint
      # some new ones
      ac.tStore(0xaa, 3, 77)
      ac.tStore(0xbb, 1, 55)
      ac.tStore(0xcc, 7, 88)

      check ac.vts(0xaa, 3, 77)
      check ac.vts(0xbb, 1, 55)
      check ac.vts(0xcc, 7, 88)

      check ac.vts(0xaa, 3, 66) == false
      check ac.vts(0xbb, 1, 33) == false
      check ac.vts(0xbb, 2, 99)

      ac.rollback(sp)
      check ac.vts(0xaa, 3, 66)
      check ac.vts(0xbb, 1, 33)
      check ac.vts(0xbb, 2, 99)
      check ac.vts(0xcc, 7, 88) == false

      sp = ac.beginSavepoint
      ac.tStore(0xaa, 3, 44)
      ac.tStore(0xaa, 4, 55)
      ac.tStore(0xbb, 1, 22)
      ac.tStore(0xdd, 2, 66)

      ac.commit(sp)
      check ac.vts(0xaa, 3, 44)
      check ac.vts(0xaa, 4, 55)
      check ac.vts(0xbb, 1, 22)
      check ac.vts(0xbb, 1, 55) == false
      check ac.vts(0xbb, 2, 99)
      check ac.vts(0xcc, 7, 88) == false
      check ac.vts(0xdd, 2, 66)

      ac.clearTransientStorage()
      check ac.vts(0xaa, 3, 44) == false
      check ac.vts(0xaa, 4, 55) == false
      check ac.vts(0xbb, 1, 22) == false
      check ac.vts(0xbb, 1, 55) == false
      check ac.vts(0xbb, 2, 99) == false
      check ac.vts(0xcc, 7, 88) == false
      check ac.vts(0xdd, 2, 66) == false

    test "ledger contractCollision":
      # use previous hash
      var ac = LedgerRef.init(memDB)
      let addr2 = initAddr(2)
      check ac.contractCollision(addr2) == false

      ac.setStorage(addr2, 1.u256, 1.u256)
      check ac.contractCollision(addr2) == false

      ac.persist()
      check ac.contractCollision(addr2) == true

      let addr3 = initAddr(3)
      check ac.contractCollision(addr3) == false
      ac.setCode(addr3, @[0xaa.byte, 0xbb])
      check ac.contractCollision(addr3) == true

      let addr4 = initAddr(4)
      check ac.contractCollision(addr4) == false
      ac.setNonce(addr4, 1)
      check ac.contractCollision(addr4) == true

    test "Ledger storage iterator":
      var ac = LedgerRef.init(memDB, storeSlotHash = true)
      let addr2 = initAddr(2)
      ac.setStorage(addr2, 1.u256, 2.u256)
      ac.setStorage(addr2, 2.u256, 3.u256)

      var keys: seq[UInt256]
      var vals: seq[UInt256]
      for k, v in ac.cachedStorage(addr2):
        keys.add k
        vals.add v

      # before persist, there are storages in cache
      check keys.len == 2
      check vals.len == 2

      check 1.u256 in keys
      check 2.u256 in keys

      # before persist, the values are all original values
      check vals == @[0.u256, 0.u256]

      keys.reset
      vals.reset

      for k, v in ac.storage(addr2):
        keys.add k
        vals.add k

      # before persist, there are no storages in db
      check keys.len == 0
      check vals.len == 0

      ac.persist()
      for k, v in ac.cachedStorage(addr2):
        keys.add k
        vals.add v

      # after persist, there are storages in cache
      check keys.len == 2
      check vals.len == 2

      check 1.u256 in keys
      check 2.u256 in keys

      # after persist, the values are what we put into
      check 2.u256 in vals
      check 3.u256 in vals

      keys.reset
      vals.reset

      for k, v in ac.storage(addr2):
        keys.add k
        vals.add v

      # after persist, there are storages in db
      check keys.len == 2
      check vals.len == 2

      check 1.u256 in keys
      check 2.u256 in keys

      check 2.u256 in vals
      check 3.u256 in vals

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc ledgerMain*(noisy = defined(debug)) =
  noisy.runLedgerTransactionTests
  runLedgerBasicOperationsTests()

when isMainModule:
  var noisy = defined(debug)

  setErrorLevel()
  noisy.ledgerMain

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
