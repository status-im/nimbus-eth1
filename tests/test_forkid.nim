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
    (number: 15050000'u64, time: 1681338454'u64, id: (crc: 0xf0afd0e3'u32, next: 1681338455'u64)), # Last Gray Glacier block
    (number: 15050000'u64, time: 1681338455'u64, id: (crc: 0xdce96c2d'u32, next: 1710338135'u64)), # First Shanghai time
    (number: 15050000'u64, time: 1710338134'u64, id: (crc: 0xdce96c2d'u32, next: 1710338135'u64)), # Last Shanghai time
    (number: 15050000'u64, time: 1710338135'u64, id: (crc: 0x9f3d2254'u32, next: 1746612311'u64)), # First Cancun time
    (number: 15050000'u64, time: 1746612310'u64, id: (crc: 0x9f3d2254'u32, next: 1746612311'u64)), # Last Cancun time
    (number: 15050000'u64, time: 1746612311'u64, id: (crc: 0xc376cf8b'u32, next: 0'u64)),          # First Prague time
    (number: 15050000'u64, time: 2746612311'u64, id: (crc: 0xc376cf8b'u32, next: 0'u64)),          # Future Prague time
  ]

  SepoliaNetIDs = [
    (number: 0'u64,       time: 0'u64, id: (crc: 0xfe3366e7'u32, next: 1450409'u64)),             # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople, Petersburg, Istanbul, Berlin and first London block
    (number: 1450408'u64, time: 0'u64, id: (crc: 0xfe3366e7'u32, next: 1450409'u64)),             # Last London block
    (number: 1450409'u64, time: 0'u64, id: (crc: 0x4a85c09c'u32, next: 1677557088'u64)),          # First MergeNetsplit block
    (number: 1450410'u64, time: 1677557087'u64, id: (crc: 0x4a85c09c'u32, next: 1677557088'u64)), # Last MergeNetsplit block
    (number: 1450410'u64, time: 1677557088'u64, id: (crc: 0xce82fa52'u32, next: 1706655072'u64)), # First Shanghai time
    (number: 1450410'u64, time: 1706655071'u64, id: (crc: 0xce82fa52'u32, next: 1706655072'u64)), # Last Shanghai time
    (number: 1450410'u64, time: 1706655072'u64, id: (crc: 0xa6260961'u32, next: 1741159776'u64)), # First Cancun time
    (number: 1450410'u64, time: 1741159775'u64, id: (crc: 0xa6260961'u32, next: 1741159776'u64)), # Last Cancun time
    (number: 1450410'u64, time: 1741159776'u64, id: (crc: 0x1cd80755'u32, next: 1760427360'u64)), # First Prague time
    (number: 1450410'u64, time: 1760427359'u64, id: (crc: 0x1cd80755'u32, next: 1760427360'u64)), # Last Prague time
    (number: 1450410'u64, time: 1760427360'u64, id: (crc: 0x55369A33'u32, next: 1761017184'u64)), # First Osaka time
    (number: 1450410'u64, time: 1761017183'u64, id: (crc: 0x55369A33'u32, next: 1761017184'u64)), # Last Osaka time
    (number: 1450410'u64, time: 1761017184'u64, id: (crc: 0xA47328A8'u32, next: 1761607008'u64)), # First BPO1 time
    (number: 1450410'u64, time: 1761607007'u64, id: (crc: 0xA47328A8'u32, next: 1761607008'u64)), # Last BPO1 time
    (number: 1450410'u64, time: 1761607008'u64, id: (crc: 0x4463073B'u32, next: 0'u64)),          # First BPO2 time
    (number: 1450410'u64, time: 1761607009'u64, id: (crc: 0x4463073B'u32, next: 0'u64)),          # Future BPO2 time
  ]

  HoodiNetIDs = [
    (number: 0'u64,   time: 0'u64, id: (crc: 0xBEF71D30'u32, next: 1742999832'u64)),          # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople, Petersburg, Istanbul, Berlin, London, Paris, Shanghai, Cancun block
    (number: 123'u64, time: 1742999831'u64, id: (crc: 0xBEF71D30'u32, next: 1742999832'u64)), # Last Cancun time
    (number: 123'u64, time: 1742999832'u64, id: (crc: 0x0929E24E'u32, next: 1761677592'u64)), # First Prague time
    (number: 123'u64, time: 1761677591'u64, id: (crc: 0x0929E24E'u32, next: 1761677592'u64)), # Last Prague time
    (number: 123'u64, time: 1761677592'u64, id: (crc: 0xE7E0E7FF'u32, next: 1762365720'u64)), # First Osaka time
    (number: 123'u64, time: 1762365719'u64, id: (crc: 0xE7E0E7FF'u32, next: 1762365720'u64)), # Last Osaka time
    (number: 123'u64, time: 1762365720'u64, id: (crc: 0x3893353E'u32, next: 1762955544'u64)), # First BPO1 time
    (number: 123'u64, time: 1762955543'u64, id: (crc: 0x3893353E'u32, next: 1762955544'u64)), # Last BPO1 time
    (number: 123'u64, time: 1762955544'u64, id: (crc: 0x23AA1351'u32, next: 0'u64)),          # First BPO2 time
    (number: 123'u64, time: 1762955545'u64, id: (crc: 0x23AA1351'u32, next: 0'u64)),          # Future BPO2 time
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
    chainID:                       1337.u256,
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
    genesisCRC = crc32(0, genesis.computeBlockHash.data)
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

suite "Fork ID tests":
  runTest(MainNet, "MainNet")
  runTest(SepoliaNet, "SepoliaNet")
  runTest(HoodiNet, "HoodiNet")
  test "Genesis Time Fork ID":
    runGenesisTimeIdTests()
