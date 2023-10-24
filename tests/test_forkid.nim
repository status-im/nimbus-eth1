import
  unittest2,
  ../nimbus/common/common

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
    (blockNumber: 9200000'u64, id: (crc: 0xE029E991'u32, nextFork: 12244000'u64)), # First MuirGlacier block
    (blockNumber: 12243999'u64, id: (crc: 0xE029E991'u32, nextFork: 12244000'u64)), # Last MuirGlacier block
    (blockNumber: 12244000'u64, id: (crc: 0x0eb440f6'u32, nextFork: 12965000'u64)), # First Berlin block
    (blockNumber: 12964999'u64, id: (crc: 0x0eb440f6'u32, nextFork: 12965000'u64)), # Last Berlin block
    (blockNumber: 12965000'u64, id: (crc: 0xb715077d'u32, nextFork: 13773000'u64)), # First London block
    (blockNumber: 13772999'u64, id: (crc: 0xb715077d'u32, nextFork: 13773000'u64)), # Last London block
    (blockNumber: 13773000'u64, id: (crc: 0x20c327fc'u32, nextFork: 15050000'u64)), # First Arrow Glacier block
    (blockNumber: 15049999'u64, id: (crc: 0x20c327fc'u32, nextFork: 15050000'u64)), # Last Arrow Glacier block
    (blockNumber: 15050000'u64, id: (crc: 0xf0afd0e3'u32, nextFork: 0'u64)),        # First Gray Glacier block
    (blockNumber: 20000000'u64, id: (crc: 0xf0afd0e3'u32, nextFork: 0'u64)),        # Future Gray Glacier block
  ]

  GoerliNetIDs = [
    (blockNumber: 0'u64,       id: (crc: 0xa3f5ab08'u32, nextFork: 1561651'u64)), # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople and first Petersburg block
    (blockNumber: 1561650'u64, id: (crc: 0xa3f5ab08'u32, nextFork: 1561651'u64)), # Last Petersburg block
    (blockNumber: 1561651'u64, id: (crc: 0xc25efa5c'u32, nextFork: 4460644'u64)), # First Istanbul block
    (blockNumber: 4460643'u64, id: (crc: 0xc25efa5c'u32, nextFork: 4460644'u64)), # Future Istanbul block
    (blockNumber: 4460644'u64, id: (crc: 0x757a1c47'u32, nextFork: 5062605'u64)), # First Berlin block
    (blockNumber: 5062604'u64, id: (crc: 0x757a1c47'u32, nextFork: 5062605'u64)), # Last Berlin block
    (blockNumber: 5062605'u64, id: (crc: 0xb8c6299d'u32, nextFork: 0'u64)),       # First London block
    (blockNumber: 10000000'u64, id: (crc: 0xb8c6299d'u32, nextFork: 0'u64)),      # Future London block
  ]

template runTest(network: untyped, name: string) =
  test name:
    var
      params = networkParams(network)
      com    = CommonRef.new(newCoreDbRef LegacyDbMemory, true, network, params)

    for x in `network IDs`:
      let id = com.forkId(x.blockNumber.toBlockNumber.blockNumberToForkDeterminationInfo)
      check id.crc == x.id.crc
      check id.nextFork == x.id.nextFork

proc forkIdMain*() =
  suite "Fork ID tests":
    runTest(MainNet, "MainNet")
    runTest(GoerliNet, "GoerliNet")

when isMainModule:
  forkIdMain()
