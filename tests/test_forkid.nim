import
  unittest2, eth/common, eth/trie/db,
  ../nimbus/db/db_chain, ../nimbus/p2p/chain,
  ../nimbus/config

const
  MainNetIDs = [
    (blockNumber: 0'u64,       id: (crc: 0xfc64ec04'u32, nextFork: 1150000'u64)), # Unsynced
    (blockNumber: 1149999'u64, id: (crc: 0xfc64ec04'u32, nextFork: 1150000'u64)), # Last Frontier block
    (blockNumber: 1150000'u64, id: (crc: 0x97c2c34c'u32, nextFork: 1920000'u64)), # First Homestead block
    (blockNumber: 1919999'u64, id: (crc: 0x97c2c34c'u32, nextFork: 1920000'u64)), # Last Homestead block
    (blockNumber: 1920000'u64, id: (crc: 0x91d1f948'u32, nextFork: 2463000'u64)), # First DAO block
    (blockNumber: 2462999'u64, id: (crc: 0x91d1f948'u32, nextFork: 2463000'u64)), # Last DAO block
    (blockNumber: 2463000'u64, id: (crc: 0x7a64da13'u32, nextFork: 2675000'u64)), # First Tangerine block
    (blockNumber: 2674999'u64, id: (crc: 0x7a64da13'u32, nextFork: 2675000'u64)), # Last Tangerine block
    (blockNumber: 2675000'u64, id: (crc: 0x3edd5b10'u32, nextFork: 4370000'u64)), # First Spurious block
    (blockNumber: 4369999'u64, id: (crc: 0x3edd5b10'u32, nextFork: 4370000'u64)), # Last Spurious block
    (blockNumber: 4370000'u64, id: (crc: 0xa00bc324'u32, nextFork: 7280000'u64)), # First Byzantium block
    (blockNumber: 7279999'u64, id: (crc: 0xa00bc324'u32, nextFork: 7280000'u64)), # Last Byzantium block
    (blockNumber: 7280000'u64, id: (crc: 0x668db0af'u32, nextFork: 9069000'u64)), # First and last Constantinople, first Petersburg block
    (blockNumber: 7987396'u64, id: (crc: 0x668db0af'u32, nextFork: 9069000'u64)), # Past Petersburg block
    (blockNumber: 9068999'u64, id: (crc: 0x668db0af'u32, nextFork: 9069000'u64)), # Last Petersburg block
    (blockNumber: 9069000'u64, id: (crc: 0x879D6E30'u32, nextFork: 9200000'u64)), # First Istanbul block
    (blockNumber: 9199999'u64, id: (crc: 0x879D6E30'u32, nextFork: 9200000'u64)), # Last Istanbul block
    (blockNumber: 9200000'u64, id: (crc: 0xE029E991'u32, nextFork: 0'u64))      , # First MuirGlacier block
    (blockNumber: 10000000'u64, id: (crc: 0xE029E991'u32, nextFork: 0'u64))     , # Past MuirGlacier block
  ]

  RopstenNetIDs = [
    (blockNumber: 0'u64,       id: (crc: 0x30c7ddbc'u32, nextFork: 10'u64)),      # Unsynced, last Frontier, Homestead and first Tangerine block
    (blockNumber: 9'u64,       id: (crc: 0x30c7ddbc'u32, nextFork: 10'u64)),      # Last Tangerine block
    (blockNumber: 10'u64,      id: (crc: 0x63760190'u32, nextFork: 1700000'u64)), # First Spurious block
    (blockNumber: 1699999'u64, id: (crc: 0x63760190'u32, nextFork: 1700000'u64)), # Last Spurious block
    (blockNumber: 1700000'u64, id: (crc: 0x3ea159c7'u32, nextFork: 4230000'u64)), # First Byzantium block
    (blockNumber: 4229999'u64, id: (crc: 0x3ea159c7'u32, nextFork: 4230000'u64)), # Last Byzantium block
    (blockNumber: 4230000'u64, id: (crc: 0x97b544f3'u32, nextFork: 4939394'u64)), # First Constantinople block
    (blockNumber: 4939393'u64, id: (crc: 0x97b544f3'u32, nextFork: 4939394'u64)), # Last Constantinople block
    (blockNumber: 4939394'u64, id: (crc: 0xd6e2149b'u32, nextFork: 6485846'u64)), # First Petersburg block
    (blockNumber: 6485845'u64, id: (crc: 0xd6e2149b'u32, nextFork: 6485846'u64)), # Last Petersburg block
    (blockNumber: 6485846'u64, id: (crc: 0x4bc66396'u32, nextFork: 7117117'u64)), # First Istanbul block
    (blockNumber: 7117116'u64, id: (crc: 0x4bc66396'u32, nextFork: 7117117'u64)), # Last Istanbul block
    (blockNumber: 7117117'u64, id: (crc: 0x6727EF90'u32, nextFork: 0'u64)),       # First MuirGlacier block
    (blockNumber: 7500000'u64, id: (crc: 0x6727EF90'u32, nextFork: 0'u64)),       # Future MuirGlacier block
  ]

  RinkebyNetIDs = [
    (blockNumber: 0'u64,       id: (crc: 0x3b8e0691'u32, nextFork: 1'u64)),       # Unsynced, last Frontier block
    (blockNumber: 1'u64,       id: (crc: 0x60949295'u32, nextFork: 2'u64)),       # First and last Homestead block
    (blockNumber: 2'u64,       id: (crc: 0x8bde40dd'u32, nextFork: 3'u64)),       # First and last Tangerine block
    (blockNumber: 3'u64,       id: (crc: 0xcb3a64bb'u32, nextFork: 1035301'u64)), # First Spurious block
    (blockNumber: 1035300'u64, id: (crc: 0xcb3a64bb'u32, nextFork: 1035301'u64)), # Last Spurious block
    (blockNumber: 1035301'u64, id: (crc: 0x8d748b57'u32, nextFork: 3660663'u64)), # First Byzantium block
    (blockNumber: 3660662'u64, id: (crc: 0x8d748b57'u32, nextFork: 3660663'u64)), # Last Byzantium block
    (blockNumber: 3660663'u64, id: (crc: 0xe49cab14'u32, nextFork: 4321234'u64)), # First Constantinople block
    (blockNumber: 4321233'u64, id: (crc: 0xe49cab14'u32, nextFork: 4321234'u64)), # Last Constantinople block
    (blockNumber: 4321234'u64, id: (crc: 0xafec6b27'u32, nextFork: 5435345'u64)), # First Petersburg block
    (blockNumber: 5435344'u64, id: (crc: 0xafec6b27'u32, nextFork: 5435345'u64)), # Last Petersburg block
    (blockNumber: 5435345'u64, id: (crc: 0xcbdb8838'u32, nextFork: 0'u64)),       # First Istanbul block
    (blockNumber: 6000000'u64, id: (crc: 0xcbdb8838'u32, nextFork: 0'u64)),       # Future Istanbul block
  ]

  GoerliNetIDs = [
    (blockNumber: 0'u64,       id: (crc: 0xa3f5ab08'u32, nextFork: 1561651'u64)), # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople and first Petersburg block
    (blockNumber: 1561650'u64, id: (crc: 0xa3f5ab08'u32, nextFork: 1561651'u64)), # Last Petersburg block
    (blockNumber: 1561651'u64, id: (crc: 0xc25efa5c'u32, nextFork: 0'u64)),       # First Istanbul block
    (blockNumber: 2000000'u64, id: (crc: 0xc25efa5c'u32, nextFork: 0'u64)),       # Future Istanbul block
  ]

template runTest(network: PublicNetwork) =
  test network.astToStr:
    var
      memDB = newMemoryDB()
      chainDB = newBaseChainDB(memDB, true, network)
      chain = newChain(chainDB)

    for x in `network IDs`:
      let id = chain.getForkId(x.blockNumber.toBlockNumber)
      check id.crc == x.id.crc
      check id.nextFork == x.id.nextFork

proc forkIdMain*() =
  suite "Fork ID tests":
    runTest(MainNet)
    runTest(RopstenNet)
    runTest(RinkebyNet)
    runTest(GoerliNet)

when isMainModule:
  forkIdMain()
