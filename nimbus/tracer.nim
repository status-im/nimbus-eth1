import
  db/[db_chain, state_db, capturedb], eth_common, utils, json,
  constants, vm_state, vm_types, transaction, p2p/executor,
  eth_trie/db, nimcrypto, strutils, ranges, ./utils/addresses

proc getParentHeader(self: BaseChainDB, header: BlockHeader): BlockHeader =
  self.getBlockHeader(header.parentHash)

proc prefixHex(x: openArray[byte]): string =
  "0x" & toHex(x, true)

proc toJson(db: AccountStateDB, address: EthAddress, name: string): JsonNode =
  result = newJObject()
  result["name"] = %name
  result["address"] = %($address)
  let account = db.getAccount(address)
  result["nonce"] = %(account.nonce.toHex)
  result["balance"] = %(account.balance.toHex)

  let code = db.getCode(address)
  result["codeHash"] = %($account.codeHash)
  result["code"] = %(toHex(code.toOpenArray, true))
  result["storageRoot"] = %($account.storageRoot)

  var storage = newJObject()
  for key, value in db.storage(address):
    storage[key.dumpHex] = %(value.dumpHex)
  result["storage"] = storage

proc captureStateAccount(n: JsonNode, db: AccountStateDB, sender: EthAddress, header: BlockHeader, tx: Transaction) =
  n.add toJson(db, sender, "sender")
  n.add toJson(db, header.coinbase, "miner")

  if tx.isContractCreation:
    let contractAddress = generateAddress(sender, tx.accountNonce)
    n.add toJson(db, contractAddress, "contract")
  else:
    n.add toJson(db, tx.to, "recipient")

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
    vmState = newBaseVMState(parent, captureChainDB, tracerFlags)

  var stateDb = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)
  if header.txRoot == BLANK_ROOT_HASH: return
  assert(body.transactions.calcTxRoot == header.txRoot)
  assert(body.transactions.len != 0)

  var
    gasUsed: GasInt
    before = newJObject()
    after = newJObject()
    stateDiff = %{"before": before, "after": after}

  for idx, tx in body.transactions:
    var sender: EthAddress
    if tx.getSender(sender):
      if idx == txIndex:
        vmState.enableTracing()
        before.captureStateAccount(stateDb, sender, header, tx)

      let txFee = processTransaction(stateDb, tx, sender, vmState)
      gasUsed = (txFee div tx.gasPrice.u256).truncate(GasInt)

      if idx == txIndex:
        vmState.disableTracing()
        after.captureStateAccount(stateDb, sender, header, tx)
        break
    else:
      assert(false, "Could not get sender")

  result = vmState.getTracingResult()
  result["gas"] = %gasUsed
  result["statediff"] = stateDiff

  # now we dump captured state db
  if TracerFlags.DisableState notin tracerFlags:
    var n = newJObject()
    for k, v in pairsInMemoryDB(memoryDB):
      n[k.prefixHex] = %v.prefixHex
    result["state"] = n
