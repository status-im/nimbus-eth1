# Nimbus
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strutils,
  unittest2,
  ../execution_chain/common/common,
  ../execution_chain/utils/utils

const
  MainNetIDs = [
    (number: 0'u64       , time: 0'u64, id: (crc: 0xfc64ec04'u32, next: 1150000'u64)), # Unsynced
    (number: 1149999'u64 , time: 0'u64, id: (crc: 0xfc64ec04'u32, next: 1150000'u64)), # Last Frontier block
    (number: 1150000'u64 , time: 0'u64, id: (crc: 0x97c2c34c'u32, next: 1920000'u64)), # First Homestead block
    (number: 1919999'u64 , time: 0'u64, id: (crc: 0x97c2c34c'u32, next: 1920000'u64)), # Last Homestead block
    (number: 1920000'u64 , time: 0'u64, id: (crc: 0x91d1f948'u32, next: 2463000'u64)), # First DAO block
    (number: 2462999'u64 , time: 0'u64, id: (crc: 0x91d1f948'u32, next: 2463000'u64)), # Last DAO block
    (number: 2463000'u64 , time: 0'u64, id: (crc: 0x7a64da13'u32, next: 2675000'u64)), # First Tangerine block
    (number: 2674999'u64 , time: 0'u64, id: (crc: 0x7a64da13'u32, next: 2675000'u64)), # Last Tangerine block
    (number: 2675000'u64 , time: 0'u64, id: (crc: 0x3edd5b10'u32, next: 4370000'u64)), # First Spurious block
    (number: 4369999'u64 , time: 0'u64, id: (crc: 0x3edd5b10'u32, next: 4370000'u64)), # Last Spurious block
    (number: 4370000'u64 , time: 0'u64, id: (crc: 0xa00bc324'u32, next: 7280000'u64)), # First Byzantium block
    (number: 7279999'u64 , time: 0'u64, id: (crc: 0xa00bc324'u32, next: 7280000'u64)), # Last Byzantium block
    (number: 7280000'u64 , time: 0'u64, id: (crc: 0x668db0af'u32, next: 9069000'u64)), # First and last Constantinople, first Petersburg block
    (number: 7987396'u64 , time: 0'u64, id: (crc: 0x668db0af'u32, next: 9069000'u64)), # Past Petersburg block
    (number: 9068999'u64 , time: 0'u64, id: (crc: 0x668db0af'u32, next: 9069000'u64)), # Last Petersburg block
    (number: 9069000'u64 , time: 0'u64, id: (crc: 0x879D6E30'u32, next: 9200000'u64)), # First Istanbul block
    (number: 9199999'u64 , time: 0'u64, id: (crc: 0x879D6E30'u32, next: 9200000'u64)), # Last Istanbul block
    (number: 9200000'u64 , time: 0'u64, id: (crc: 0xE029E991'u32, next: 12244000'u64)), # First MuirGlacier block
    (number: 12243999'u64, time: 0'u64, id: (crc: 0xE029E991'u32, next: 12244000'u64)), # Last MuirGlacier block
    (number: 12244000'u64, time: 0'u64, id: (crc: 0x0eb440f6'u32, next: 12965000'u64)), # First Berlin block
    (number: 12964999'u64, time: 0'u64, id: (crc: 0x0eb440f6'u32, next: 12965000'u64)), # Last Berlin block
    (number: 12965000'u64, time: 0'u64, id: (crc: 0xb715077d'u32, next: 13773000'u64)), # First London block
    (number: 13772999'u64, time: 0'u64, id: (crc: 0xb715077d'u32, next: 13773000'u64)), # Last London block
    (number: 13773000'u64, time: 0'u64, id: (crc: 0x20c327fc'u32, next: 15050000'u64)), # First Arrow Glacier block
    (number: 15049999'u64, time: 0'u64, id: (crc: 0x20c327fc'u32, next: 15050000'u64)), # Last Arrow Glacier block
    (number: 15050000'u64, time: 0'u64, id: (crc: 0xf0afd0e3'u32, next: 1681338455'u64)), # First Gray Glacier block
    (number: 20000000'u64, time: 1681338454'u64, id: (crc: 0xf0afd0e3'u32, next: 1681338455'u64)), # Last Gray Glacier block
    (number: 20000000'u64, time: 1681338455'u64, id: (crc: 0xdce96c2d'u32, next: 1710338135'u64)), # First Shanghai block
    (number: 30000000'u64, time: 1710338134'u64, id: (crc: 0xdce96c2d'u32, next: 1710338135'u64)), # Last Shanghai block
    (number: 40000000'u64, time: 1710338135'u64, id: (crc: 0x9f3d2254'u32, next: 0'u64)),          # First Cancun block
    (number: 50000000'u64, time: 2000000000'u64, id: (crc: 0x9f3d2254'u32, next: 0'u64)),          # Future Cancun block
  ]

  SepoliaNetIDs = [
    (number: 0'u64,       time: 0'u64, id: (crc: 0xfe3366e7'u32, next: 1450409'u64)),             # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople, Petersburg, Istanbul, Berlin and first London block
    (number: 1450408'u64, time: 0'u64, id: (crc: 0xfe3366e7'u32, next: 1450409'u64)),             # Last London block
    (number: 1450409'u64, time: 0'u64, id: (crc: 0x4a85c09c'u32, next: 1677557088'u64)),          # First MergeNetsplit block
    (number: 1450410'u64, time: 1677557087'u64, id: (crc: 0x4a85c09c'u32, next: 1677557088'u64)), # Last MergeNetsplit block
    (number: 1450410'u64, time: 1677557088'u64, id: (crc: 0xce82fa52'u32, next: 1706655072'u64)), # First Shanghai block
    (number: 1450410'u64, time: 1706655071'u64, id: (crc: 0xce82fa52'u32, next: 1706655072'u64)), # Last Shanghai block
    (number: 1450410'u64, time: 1706655072'u64, id: (crc: 0xa6260961'u32, next: 1741159776'u64)), # First Cancun block
    (number: 1450410'u64, time: 1741159775'u64, id: (crc: 0xa6260961'u32, next: 1741159776'u64)), # Last Cancun block
    (number: 1450410'u64, time: 1741159776'u64, id: (crc: 0x1cd80755'u32, next: 0'u64)), # First Prague block
    (number: 1450410'u64, time: 2741159776'u64, id: (crc: 0x1cd80755'u32, next: 0'u64)), # Future Prague block
  ]

  HoleskyNetIDs = [
    (number: 0'u64,   time: 0'u64, id: (crc: 0xc61a6098'u32, next: 1696000704'u64)), # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople, Petersburg, Istanbul, Berlin, London, Paris block
    (number: 123'u64, time: 0'u64, id: (crc: 0xc61a6098'u32, next: 1696000704'u64)), # First MergeNetsplit block
    (number: 123'u64, time: 1696000704'u64, id: (crc: 0xfd4f016b'u32, next: 1707305664'u64)), # First Shanghai block
    (number: 123'u64, time: 1707305663'u64, id: (crc: 0xfd4f016b'u32, next: 1707305664'u64)), # Last Shanghai block
    (number: 123'u64, time: 1707305664'u64, id: (crc: 0x9b192ad0'u32, next: 1740434112'u64)), # First Cancun block
    (number: 123'u64, time: 1740434111'u64, id: (crc: 0x9b192ad0'u32, next: 1740434112'u64)), # Last Cancun block
    (number: 123'u64, time: 1740434112'u64, id: (crc: 0xdfbd9bed'u32, next: 0'u64)), # First Prague block
    (number: 123'u64, time: 2740434112'u64, id: (crc: 0xdfbd9bed'u32, next: 0'u64)), # Future Prague block
  ]

template runTest(network: untyped, name: string) =
  test name:
    var
      params = networkParams(network)
      com    = CommonRef.new(newCoreDbRef DefaultDbMemory, nil, network, params)

    for i, x in `network IDs`:
      let id = com.forkId(x.number, x.time)
      check toHex(id.crc) == toHex(x.id.crc)
      check id.nextFork == x.id.next

func config(shanghai, cancun: uint64): ChainConfig =
  ChainConfig(
    chainID:                       ChainId(1337),
    homesteadBlock:                Opt.some(0'u64),
    dAOForkBlock:                  Opt.none(BlockNumber),
    dAOForkSupport:                true,
    eIP150Block:                   Opt.some(0'u64),
    eIP155Block:                   Opt.some(0'u64),
    eIP158Block:                   Opt.some(0'u64),
    byzantiumBlock:                Opt.some(0'u64),
    constantinopleBlock:           Opt.some(0'u64),
    petersburgBlock:               Opt.some(0'u64),
    istanbulBlock:                 Opt.some(0'u64),
    muirGlacierBlock:              Opt.some(0'u64),
    berlinBlock:                   Opt.some(0'u64),
    londonBlock:                   Opt.some(0'u64),
    terminalTotalDifficulty:       Opt.some(0.u256),
    mergeNetsplitBlock:            Opt.some(0'u64),
    shanghaiTime:                  Opt.some(shanghai.EthTime),
    cancunTime:                    Opt.some(cancun.EthTime),
  )

func calcID(conf: ChainConfig, crc: uint32, time: uint64): ForkID =
  let map  = conf.toForkTransitionTable
  let calc = map.initForkIdCalculator(crc, time)
  calc.newID(0, time)

template runGenesisTimeIdTests() =
  let
    time       = 1690475657'u64
    genesis    = common.Header(timestamp: time.EthTime)
    genesisCRC = crc32(0, genesis.blockHash.data)
    cases = [
      # Shanghai active before genesis, skip
      (c: config(time-1, time+1), want: (crc: genesisCRC, next: time + 1)),

      # Shanghai active at genesis, skip
      (c: config(time, time+1), want: (crc: genesisCRC, next: time + 1)),

      # Shanghai not active, skip
      (c: config(time+1, time+2), want: (crc: genesisCRC, next: time + 1)),
    ]

  for i, x in cases:
    let get = calcID(x.c, genesisCRC, time)
    check get.crc == x.want.crc
    check get.nextFork == x.want.next

proc forkIdMain*() =
  suite "Fork ID tests":
    runTest(MainNet, "MainNet")
    runTest(SepoliaNet, "SepoliaNet")
    runTest(HoleskyNet, "HoleskyNet")
    test "Genesis Time Fork ID":
      runGenesisTimeIdTests()

when isMainModule:
  forkIdMain()
