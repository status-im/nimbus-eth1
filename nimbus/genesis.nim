import
  tables, json, times,
  eth/[common, rlp, trie], stint, stew/[byteutils],
  chronicles, eth/trie/db,
  db/[db_chain, state_db], genesis_alloc, config, constants

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
    nonce*: AccountNonce

func toAddress(n: UInt256): EthAddress =
  let a = n.toByteArrayBE()
  result[0 .. ^1] = a.toOpenArray(12, a.high)

func decodePrealloc(data: seq[byte]): GenesisAlloc =
  result = newTable[EthAddress, GenesisAccount]()
  for tup in rlp.decode(data, seq[(UInt256, UInt256)]):
    result[toAddress(tup[0])] = GenesisAccount(balance: tup[1])

proc customNetPrealloc(genesisBlock: JsonNode): GenesisAlloc =
  result = newTable[EthAddress, GenesisAccount]()
  for address, balance in genesisBlock.pairs():
    let balance = fromHex(UInt256,balance["balance"].getStr())
    result[parseAddress(address)] = GenesisAccount(balance: balance)

proc defaultGenesisBlockForNetwork*(id: PublicNetwork): Genesis =
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
      nonce: 0.toBlockNonce,
      timestamp: initTime(0x58ee40ba, 0),
      extraData: hexToSeqByte("0x52657370656374206d7920617574686f7269746168207e452e436172746d616e42eb768f2244c8811c63729a21a3569731535f067ffc57839b00206d1ad20c69a1981b489f772031b279182d99e65703f0076e4812653aab85fca0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
      gasLimit: 4700000,
      difficulty: 1.u256,
      alloc: decodePrealloc(rinkebyAllocData)
    )
  of GoerliNet:
    Genesis(
      nonce: 0.toBlockNonce,
      timestamp: initTime(0x5c51a607, 0),
      extraData: hexToSeqByte("0x22466c6578692069732061207468696e6722202d204166726900000000000000e0a2bd4258d2768837baa26a28fe71dc079f84c70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
      gasLimit: 0xa00000,
      difficulty: 1.u256,
      alloc: decodePrealloc(goerliAllocData)
    )
  of CustomNet:
    let genesis = getConfiguration().customGenesis
    var alloc = new GenesisAlloc
    if genesis.prealloc != parseJson("{}"):
      alloc = customNetPrealloc(genesis.prealloc)
    Genesis(
      nonce: genesis.nonce,
      extraData: genesis.extraData,
      gasLimit: genesis.gasLimit,
      difficulty: genesis.difficulty,
      alloc: alloc,
      timestamp: genesis.timestamp,
      mixhash: genesis.mixHash,
      coinbase: genesis.coinbase
    )

  else:
    # TODO: Fill out the rest
    error "No default genesis for network", id
    doAssert(false, "No default genesis for " & $id)
    Genesis()
  result.config = publicChainConfig(id)

proc toBlock*(g: Genesis, db: BaseChainDB = nil): BlockHeader =
  let (tdb, pruneTrie) = if db.isNil: (newMemoryDB(), true)
                         else: (db.db, db.pruneTrie)
  var trie = initHexaryTrie(tdb)
  var sdb = newAccountStateDB(tdb, trie.rootHash, pruneTrie)

  for address, account in g.alloc:
    sdb.setAccount(address, newAccount(account.nonce, account.balance))
    sdb.setCode(address, account.code)
    for k, v in account.storage:
      sdb.setStorage(address, k, v)

  var root = sdb.rootHash

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
  let b = g.toBlock(db)
  doAssert(b.blockNumber == 0, "can't commit genesis block with number > 0")
  discard db.persistHeaderToDb(b)

proc initializeEmptyDb*(db: BaseChainDB) =
  trace "Writing genesis to DB"
  let networkId = getConfiguration().net.networkId.toPublicNetwork()
#  if networkId == CustomNet:
#    raise newException(Exception, "Custom genesis not implemented")
#  else:
  defaultGenesisBlockForNetwork(networkId).commit(db)
