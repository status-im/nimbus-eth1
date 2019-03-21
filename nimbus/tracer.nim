import
  db/[db_chain, state_db, capturedb], eth/common, utils, json,
  constants, vm_state, vm_types, transaction, p2p/executor,
  eth/trie/db, nimcrypto, strutils, ranges,
  chronicles, rpc/hexstrings, launcher

proc getParentHeader(self: BaseChainDB, header: BlockHeader): BlockHeader =
  self.getBlockHeader(header.parentHash)

proc `%`(x: openArray[byte]): JsonNode =
  result = %toHex(x, false)

proc toJson(receipt: Receipt): JsonNode =
  result = newJObject()

  result["cumulativeGasUsed"] = %receipt.cumulativeGasUsed
  result["bloom"] = %receipt.bloom
  result["logs"] = %receipt.logs

  if receipt.hasStateRoot:
    result["root"] = %($receipt.stateRoot)
  else:
    result["status"] = %receipt.status

proc dumpReceipts*(chainDB: BaseChainDB, header: BlockHeader): JsonNode =
  result = newJArray()
  for receipt in chainDB.getReceipts(header):
    result.add receipt.toJson

proc toJson*(receipts: seq[Receipt]): JsonNode =
  result = newJArray()
  for receipt in receipts:
    result.add receipt.toJson

proc captureAccount(n: JsonNode, db: AccountStateDB, address: EthAddress, name: string) =
  var jaccount = newJObject()
  jaccount["name"] = %name
  jaccount["address"] = %("0x" & $address)
  let account = db.getAccount(address)
  jaccount["nonce"] = %(encodeQuantity(account.nonce).toLowerAscii)
  jaccount["balance"] = %("0x" & account.balance.toHex)

  let code = db.getCode(address)
  jaccount["codeHash"] = %("0x" & ($account.codeHash).toLowerAscii)
  jaccount["code"] = %("0x" & toHex(code.toOpenArray, true))
  jaccount["storageRoot"] = %("0x" & ($account.storageRoot).toLowerAscii)

  var storage = newJObject()
  for key, value in db.storage(address):
    storage["0x" & key.dumpHex] = %("0x" & value.dumpHex)
  jaccount["storage"] = storage

  n.add jaccount

proc dumpMemoryDB*(node: JsonNode, memoryDB: TrieDatabaseRef) =
  var n = newJObject()
  for k, v in pairsInMemoryDB(memoryDB):
    n[k.toHex(false)] = %v
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
    vmState = newBaseVMState(parent.stateRoot, header, captureChainDB, tracerFlags + {EnableAccount})

  var stateDb = vmState.accountDb

  if header.txRoot == BLANK_ROOT_HASH: return newJNull()
  doAssert(body.transactions.calcTxRoot == header.txRoot)
  doAssert(body.transactions.len != 0)

  var
    gasUsed: GasInt
    before = newJArray()
    after = newJArray()
    stateDiff = %{"before": before, "after": after}
    beforeRoot: Hash256

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient

    if idx == txIndex:
      vmState.enableTracing()
      before.captureAccount(stateDb, sender, senderName)
      before.captureAccount(stateDb, recipient, recipientName)
      before.captureAccount(stateDb, header.coinbase, minerName)
      stateDiff["beforeRoot"] = %($stateDb.rootHash)
      beforeRoot = stateDb.rootHash

    gasUsed = processTransaction(tx, sender, vmState)
    vmState.mutateStateDB:
      let txFee = gasUsed.u256 * tx.gasPrice.u256
      db.addBalance(header.coinbase, txFee)

    if idx == txIndex:
      after.captureAccount(stateDb, sender, senderName)
      after.captureAccount(stateDb, recipient, recipientName)
      after.captureAccount(stateDb, header.coinbase, minerName)
      vmState.removeTracedAccounts(sender, recipient, header.coinbase)
      stateDiff["afterRoot"] = %($stateDb.rootHash)
      break

  # internal transactions:
  var stateBefore = newAccountStateDB(captureTrieDB, beforeRoot, db.pruneTrie)
  for idx, acc in tracedAccountsPairs(vmState):
    before.captureAccount(stateBefore, acc, internalTxName & $idx)

  for idx, acc in tracedAccountsPairs(vmState):
    after.captureAccount(stateDb, acc, internalTxName & $idx)

  result = vmState.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableStateDiff notin tracerFlags:
    result["stateDiff"] = stateDiff

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
    vmState = newBaseVMState(parent.stateRoot, header, captureChainDB, {EnableTracing, DisableMemory, DisableStorage, EnableAccount})

  var
    before = newJArray()
    after = newJArray()
    stateBefore = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient
    before.captureAccount(stateBefore, sender, senderName & $idx)
    before.captureAccount(stateBefore, recipient, recipientName & $idx)

  before.captureAccount(stateBefore, header.coinbase, minerName)

  for idx, uncle in body.uncles:
    before.captureAccount(stateBefore, uncle.coinbase, uncleName & $idx)

  discard captureChainDB.processBlock(header, body, vmState)

  var stateAfter = vmState.accountDb

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient
    after.captureAccount(stateAfter, sender, senderName & $idx)
    after.captureAccount(stateAfter, recipient, recipientName & $idx)
    vmState.removeTracedAccounts(sender, recipient)

  after.captureAccount(stateAfter, header.coinbase, minerName)
  vmState.removeTracedAccounts(header.coinbase)

  for idx, uncle in body.uncles:
    after.captureAccount(stateAfter, uncle.coinbase, uncleName & $idx)
    vmState.removeTracedAccounts(uncle.coinbase)

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
    vmState = newBaseVMState(parent.stateRoot, header, captureChainDB, tracerFlags + {EnableTracing})

  if header.txRoot == BLANK_ROOT_HASH: return newJNull()
  doAssert(body.transactions.calcTxRoot == header.txRoot)
  doAssert(body.transactions.len != 0)

  var gasUsed = GasInt(0)

  for tx in body.transactions:
    let sender = tx.getSender
    gasUsed = gasUsed + processTransaction(tx, sender, vmState)

  result = vmState.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableState notin tracerFlags:
    result.dumpMemoryDB(memoryDB)

proc traceTransactions*(chainDB: BaseChainDB, header: BlockHeader, blockBody: BlockBody): JsonNode =
  result = newJArray()
  for i in 0 ..< blockBody.transactions.len:
    result.add traceTransaction(chainDB, header, blockBody, i, {DisableState})

proc dumpDebuggingMetaData*(chainDB: BaseChainDB, header: BlockHeader,
                            blockBody: BlockBody, vmState: BaseVMState, launchDebugger = true) =
  let
    blockNumber = header.blockNumber

  var
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(chainDB.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)
    bloom = createBloom(vmState.receipts)

  let blockSummary = %{
    "receiptsRoot": %("0x" & toHex(calcReceiptRoot(vmState.receipts).data)),
    "stateRoot": %("0x" & toHex(vmState.accountDb.rootHash.data)),
    "logsBloom": %("0x" & toHex(bloom))
  }

  var metaData = %{
    "blockNumber": %blockNumber.toHex,
    "txTraces": traceTransactions(captureChainDB, header, blockBody),
    "stateDump": dumpBlockState(captureChainDB, header, blockBody),
    "blockTrace": traceBlock(captureChainDB, header, blockBody, {DisableState}),
    "receipts": toJson(vmState.receipts),
    "block": blockSummary
  }

  metaData.dumpMemoryDB(memoryDB)

  let jsonFileName = "debug" & $blockNumber & ".json"
  if launchDebugger:
    launchPremix(jsonFileName, metaData)
  else:
    writeFile(jsonFileName, metaData.pretty())
