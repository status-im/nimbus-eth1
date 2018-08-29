import ../db/db_chain, eth_common, chronicles, ../vm_state, ../vm_types, ../transaction,
  ../vm/[computation, interpreter_dispatch, message]


type
  Chain* = ref object of AbstractChainDB
    db: BaseChainDB

proc newChain*(db: BaseChainDB): Chain =
  result.new
  result.db = db

method genesisHash*(c: Chain): KeccakHash =
  c.db.getBlockHash(0.toBlockNumber)

method getBlockHeader*(c: Chain, b: HashOrNum, output: var BlockHeader): bool =
  case b.isHash
  of true:
    c.db.getBlockHeader(b.hash, output)
  else:
    c.db.getBlockHeader(b.number, output)

method getBestBlockHeader*(c: Chain): BlockHeader =
  c.db.getCanonicalHead()

method getSuccessorHeader*(c: Chain, h: BlockHeader, output: var BlockHeader): bool =
  let n = h.blockNumber + 1
  c.db.getBlockHeader(n, output)

method getBlockBody*(c: Chain, blockHash: KeccakHash): BlockBodyRef =
  result = nil

method persistBlocks*(c: Chain, headers: openarray[BlockHeader], bodies: openarray[BlockBody]) =
  # Run the VM here
  assert(headers.len == bodies.len)

  for i in 0 ..< headers.len:
    let head = c.db.getCanonicalHead()
    # assert(head.blockNumber == headers[i].blockNumber - 1)
    let vmState = newBaseVMState(head, c.db)
    if bodies[i].transactions.len != 0:
      # echo "block: ", headers[i].blockNumber
      for t in bodies[i].transactions:
        var msg: Message
        # echo "trns: ", t

        # let msg = newMessage(t.gasLimit, t.gasPrice, t.to, t.getSender, 

      # let c = newBaseComputation(vmState, 

  discard
