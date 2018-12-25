import
  db/[db_chain, state_db, capturedb], eth_common, utils, json,
  constants, vm_state, vm_types, transaction, p2p/executor,
  eth_trie/db, nimcrypto, strutils, ranges, ./utils/addresses,
  chronicles

proc getParentHeader(self: BaseChainDB, header: BlockHeader): BlockHeader =
  self.getBlockHeader(header.parentHash)

proc prefixHex(x: openArray[byte]): string =
  "0x" & toHex(x, true)

proc getSender(tx: Transaction): EthAddress =
  if not tx.getSender(result):
    raise newException(ValueError, "Could not get sender")

proc getRecipient(tx: Transaction): EthAddress =
  if tx.isContractCreation:
    let sender = tx.getSender()
    result = generateAddress(sender, tx.accountNonce)
  else:
    result = tx.to

proc captureAccount(n: JsonNode, db: AccountStateDB, address: EthAddress, name: string) =
  var jaccount = newJObject()
  jaccount["name"] = %name
  jaccount["address"] = %($address)
  let account = db.getAccount(address)
  jaccount["nonce"] = %(account.nonce.toHex)
  jaccount["balance"] = %(account.balance.toHex)

  let code = db.getCode(address)
  jaccount["codeHash"] = %(($account.codeHash).toLowerAscii)
  jaccount["code"] = %(toHex(code.toOpenArray, true))
  jaccount["storageRoot"] = %(($account.storageRoot).toLowerAscii)

  var storage = newJObject()
  for key, value in db.storage(address):
    storage[key.dumpHex] = %(value.dumpHex)
  jaccount["storage"] = storage

  n.add jaccount

proc dumpMemoryDB*(node: JsonNode, memoryDB: TrieDatabaseRef) =
  var n = newJObject()
  for k, v in pairsInMemoryDB(memoryDB):
    n[k.prefixHex] = %v.prefixHex
  node["state"] = n

const
  senderName = "sender"
  recipientName = "recipient"
  minerName = "miner"
  uncleName = "uncle"
  internalTxName = "internalTx"

proc traceTransaction*(db: BaseChainDB, header: BlockHeader,
                       body: BlockBody, txIndex: int, tracerFlags: set[TracerFlags] = {}): JsonNode =
  let
    parent = db.getParentHeader(header)
    # we add a memory layer between backend/lower layer db
    # and capture state db snapshot during transaction execution
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(db.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false) # prune or not prune?
    vmState = newBaseVMState(parent, captureChainDB, tracerFlags + {EnableAccount})

  var stateDb = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)
  var stateBefore = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)
  # stateDb and stateBefore will not the same after transaction execution
  if header.txRoot == BLANK_ROOT_HASH: return newJNull()
  assert(body.transactions.calcTxRoot == header.txRoot)
  assert(body.transactions.len != 0)

  var
    gasUsed: GasInt
    before = newJArray()
    after = newJArray()
    stateDiff = %{"before": before, "after": after}

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient

    if idx == txIndex:
      vmState.enableTracing()
      before.captureAccount(stateDb, sender, senderName)
      before.captureAccount(stateDb, recipient, recipientName)
      before.captureAccount(stateDb, header.coinbase, minerName)
      stateDiff["beforeRoot"] = %($vmState.blockHeader.stateRoot)

    let txFee = processTransaction(stateDb, tx, sender, vmState)
    stateDb.addBalance(header.coinbase, txFee)

    if idx == txIndex:
      gasUsed = (txFee div tx.gasPrice.u256).truncate(GasInt)
      after.captureAccount(stateDb, sender, senderName)
      after.captureAccount(stateDb, recipient, recipientName)
      after.captureAccount(stateDb, header.coinbase, minerName)
      stateDiff["afterRoot"] = %($vmState.blockHeader.stateRoot)
      break

  # internal transactions:
  for idx, acc in tracedAccountsPairs(vmState):
    before.captureAccount(stateBefore, acc, internalTxName & $idx)

  for idx, acc in tracedAccountsPairs(vmState):
    after.captureAccount(stateDb, acc, internalTxName & $idx)

  result = vmState.getTracingResult()
  result["gas"] = %gasUsed
  result["statediff"] = stateDiff

  # now we dump captured state db
  if TracerFlags.DisableState notin tracerFlags:
    result.dumpMemoryDB(memoryDB)

proc dumpBlockState*(db: BaseChainDB, header: BlockHeader, body: BlockBody, dumpState = false): JsonNode =
  let
    parent = db.getParentHeader(header)
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(db.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)
    # we only need stack dump if we want to scan for internal transaction address
    vmState = newBaseVMState(parent, captureChainDB, {EnableTracing, DisableMemory, DisableStorage, EnableAccount})

  var
    before = newJArray()
    after = newJArray()
    stateBefore = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)
    stateAfter = newAccountStateDB(captureTrieDB, header.stateRoot, db.pruneTrie)

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient
    before.captureAccount(stateBefore, sender, senderName & $idx)
    before.captureAccount(stateBefore, recipient, recipientName & $idx)

  before.captureAccount(stateBefore, header.coinbase, minerName)

  for idx, uncle in body.uncles:
    before.captureAccount(stateBefore, uncle.coinbase, uncleName & $idx)

  discard captureChainDB.processBlock(parent, header, body, vmState)

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient
    after.captureAccount(stateAfter, sender, senderName & $idx)
    after.captureAccount(stateAfter, recipient, recipientName & $idx)

  after.captureAccount(stateAfter, header.coinbase, minerName)

  for idx, uncle in body.uncles:
    after.captureAccount(stateAfter, uncle.coinbase, uncleName & $idx)

  # internal transactions:
  for idx, acc in tracedAccountsPairs(vmState):
    before.captureAccount(stateBefore, acc, internalTxName & $idx)

  for idx, acc in tracedAccountsPairs(vmState):
    after.captureAccount(stateAfter, acc, internalTxName & $idx)

  result = %{"before": before, "after": after}

  if dumpState:
    result.dumpMemoryDB(memoryDB)

proc traceBlock*(db: BaseChainDB, header: BlockHeader, body: BlockBody, tracerFlags: set[TracerFlags] = {}): JsonNode =
  let
    parent = db.getParentHeader(header)
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(db.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)
    vmState = newBaseVMState(parent, captureChainDB, tracerFlags + {EnableTracing})

  var
    stateDb = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)

  if header.txRoot == BLANK_ROOT_HASH: return newJNull()
  assert(body.transactions.calcTxRoot == header.txRoot)
  assert(body.transactions.len != 0)

  var gasUsed = GasInt(0)

  for tx in body.transactions:
    let
      sender = tx.getSender
      txFee = processTransaction(stateDb, tx, sender, vmState)
    gasUsed = gasUsed + (txFee div tx.gasPrice.u256).truncate(GasInt)

  result = vmState.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableState notin tracerFlags:
    result.dumpMemoryDB(memoryDB)

proc dumpDebuggingMetaData*(db: BaseChainDB, header: BlockHeader, body: BlockBody) =
  # TODO: tidying this up and make it available to debugging tool
  let ttrace = traceTransaction(db, header, body, body.transactions.len - 1, {})
  trace "NIMBUS TRACE", transactionTrace=ttrace.pretty()
  let dump = dumpBlockState(db, header, body)
  trace "NIMBUS STATE DUMP", dump=dump.pretty()
  let blockTrace = traceBlock(db, header, body, {})
  trace "NIMBUS BLOCK TRACE", blockTrace=blockTrace
  # dump receipt #195