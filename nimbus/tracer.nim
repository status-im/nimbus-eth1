import
  db/[db_chain, state_db, capturedb], eth_common, utils, json,
  constants, vm_state, vm_types, transaction, p2p/chain,
  eth_trie/db, nimcrypto

proc getParentHeader(self: BaseChainDB, header: BlockHeader): BlockHeader =
  self.getBlockHeader(header.parentHash)

proc prefixHex(x: openArray[byte]): string =
  "0x" & toHex(x, true)

proc traceTransaction*(db: BaseChainDB, header: BlockHeader,
                       body: BlockBody, txIndex: int, tracerFlags: set[TracerFlags]): JsonNode =
  let
    parent = db.getParentHeader(header)
    # we add a memory layer between backend/lower layer db
    # and capture state db snapshot during transaction execution
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(db.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false) # prune or not prune?
    vmState = newBaseVMState(parent, captureChainDB, tracerFlags + {TracerFlags.EnableTracing})

  var stateDb = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)
  if header.txRoot == BLANK_ROOT_HASH: return
  assert(body.transactions.calcTxRoot == header.txRoot)
  assert(body.transactions.len != 0)

  var gasUsed: GasInt
  for idx, tx in body.transactions:
    var sender: EthAddress
    if tx.getSender(sender):
      let txFee = processTransaction(stateDb, tx, sender, vmState)
      gasUsed = (txFee div tx.gasPrice.u256).truncate(GasInt)
      if idx == txIndex: break
    else:
      assert(false, "Could not get sender")

  result = vmState.getTracingResult()
  result["gas"] = %gasUsed

  # now we dump captured state db
  if TracerFlags.DisableState notin tracerFlags:
    var n = newJObject()
    for k, v in pairsInMemoryDB(memoryDB):
      n[k.prefixHex] = %v.prefixHex
    result["state"] = n
