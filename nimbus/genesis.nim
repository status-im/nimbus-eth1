import db/[db_chain, state_db], genesis_alloc, eth_common, tables, stint,
    byteutils, times, config, rlp, ranges, block_types, eth_trie,
    eth_trie/memdb, constants, nimcrypto, chronicles

type
  Genesis* = object
    config*: ChainConfig
    nonce*: BlockNonce
    timestamp*: EthTime
    extraData*: seq[byte]
    gasLimit*: GasInt
    difficulty*: DifficultyInt
    mixhash*: Hash256
    coinbase*: EthAddress
    alloc*: GenesisAlloc

  GenesisAlloc = TableRef[EthAddress, GenesisAccount]
  GenesisAccount = object
    code*: seq[byte]
    storage*: Table[UInt256, UInt256]
    balance*: UInt256
    nonce*: UInt256

func toAddress(n: UInt256): EthAddress =
  let a = n.toByteArrayBE()
  result[0 .. ^1] = a.toOpenArray(12, a.high)

func decodePrealloc(data: seq[byte]): GenesisAlloc =
  result = newTable[EthAddress, GenesisAccount]()
  for tup in rlp.decode(data.toRange, seq[(UInt256, UInt256)]):
    result[toAddress(tup[0])] = GenesisAccount(balance: tup[1])

func defaultGenesisBlockForNetwork*(id: PublicNetwork): Genesis =
  result = case id
  of MainNet:
    Genesis(
      nonce: 66.toBlockNonce,
      extraData: hexToSeqByte("0x11bbe8db4e347b4e8c937c1c8370e4b5ed33adb3db69cbdb7a38e1e50b1b82fa"),
      gasLimit: 5000,
      difficulty: 17179869184.u256,
      alloc: decodePrealloc(mainnetAllocData)
    )
  of RopstenNet:
    Genesis(
      nonce: 66.toBlockNonce,
      extraData: hexToSeqByte("0x3535353535353535353535353535353535353535353535353535353535353535"),
      gasLimit: 16777216,
      difficulty: 1048576.u256,
      alloc: decodePrealloc(testnetAllocData)
    )
  of RinkebyNet:
    Genesis(
      nonce: 66.toBlockNonce,
      extraData: hexToSeqByte("0x3535353535353535353535353535353535353535353535353535353535353535"),
      gasLimit: 16777216,
      difficulty: 1048576.u256,
      alloc: decodePrealloc(testnetAllocData)
    )
  else:
    raise newException(Exception, "No default genesis for " & $id)
  result.config = publicChainConfig(id)

proc toBlock*(g: Genesis): BlockHeader =
  let tdb = trieDB(newMemDB())
  var trie = initHexaryTrie(tdb)
  var sdb = newAccountStateDB(tdb, trie.rootHash)

  for address, account in g.alloc:
    sdb.setBalance(address, account.balance)
    sdb.setCode(address, account.code.toRange)
    sdb.setNonce(address, account.nonce)

    for k, v in account.storage:
      sdb.setStorage(address, k, v)

  var root = sdb.rootHash

  block tempRootHashStub: # TODO: Remove this block when we calculate the root hash correctly
    if g.config.chainId == 1:
      const correctMainnetRootHash = toDigest("d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544")
      if root != correctMainnetRootHash:
        error "Root hash incorrect. Stubbing it out."
        root = correctMainnetRootHash
      else:
        error "Yay! Root hash is correct. Please remove the block where this message comes from."

  result = BlockHeader(
    nonce: g.nonce,
    timestamp: g.timestamp,
    extraData: g.extraData,
    gasLimit: g.gasLimit,
    difficulty: g.difficulty,
    mixDigest: g.mixhash,
    coinbase: g.coinbase,
    stateRoot: root,
    parentHash: GENESIS_PARENT_HASH,
    txRoot: BLANK_ROOT_HASH,
    receiptRoot: BLANK_ROOT_HASH,
    ommersHash: EMPTY_UNCLE_HASH
  )

  if g.gasLimit == 0:
    result.gasLimit = GENESIS_GAS_LIMIT

  if g.difficulty == 0:
    result.difficulty = GENESIS_DIFFICULTY

proc commit*(g: Genesis, db: BaseChainDB) =
  let b = g.toBlock()
  assert(b.blockNumber == 0, "can't commit genesis block with number > 0")
  discard db.persistHeaderToDb(b)
