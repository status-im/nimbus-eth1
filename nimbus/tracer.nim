import
  db/[db_chain, state_db], eth_common, utils, json,
  constants, vm_state, vm_types, transaction, p2p/chain

proc traceTransaction*(db: BaseChainDB, header: BlockHeader,
                       body: BlockBody, txIndex: int, tracerFlags: set[TracerFlags]): JsonNode =
  let head = db.getCanonicalHead()
  assert(head.blockNumber == header.blockNumber - 1)
  var stateDb = newAccountStateDB(db.db, head.stateRoot, db.pruneTrie)
  assert(body.transactions.calcTxRoot == header.txRoot)
  if header.txRoot == BLANK_ROOT_HASH: return

  let vmState = newBaseVMState(head, db, tracerFlags + {EnableTracing})
  assert(body.transactions.len != 0)

  for idx, tx in body.transactions:
    var sender: EthAddress
    if tx.getSender(sender):
      discard processTransaction(stateDb, tx, sender, vmState)
      if idx == txIndex: break
    else:
      assert(false, "Could not get sender")

  vmState.getTracingResult()
