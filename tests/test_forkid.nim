# Nimbus
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  unittest2,
  stew/[endians2, byteutils],
  ../execution_chain/common/common,
  ../execution_chain/utils/utils

const
  MainNetIDs = [
    (number: 0'u64       , time: 0'u64, id: (hash: 0xfc64ec04'u32, next: 1150000'u64)), # Unsynced
    (number: 1149999'u64 , time: 0'u64, id: (hash: 0xfc64ec04'u32, next: 1150000'u64)), # Last Frontier block
    (number: 1150000'u64 , time: 0'u64, id: (hash: 0x97c2c34c'u32, next: 1920000'u64)), # First Homestead block
    (number: 1919999'u64 , time: 0'u64, id: (hash: 0x97c2c34c'u32, next: 1920000'u64)), # Last Homestead block
    (number: 1920000'u64 , time: 0'u64, id: (hash: 0x91d1f948'u32, next: 2463000'u64)), # First DAO block
    (number: 2462999'u64 , time: 0'u64, id: (hash: 0x91d1f948'u32, next: 2463000'u64)), # Last DAO block
    (number: 2463000'u64 , time: 0'u64, id: (hash: 0x7a64da13'u32, next: 2675000'u64)), # First Tangerine block
    (number: 2674999'u64 , time: 0'u64, id: (hash: 0x7a64da13'u32, next: 2675000'u64)), # Last Tangerine block
    (number: 2675000'u64 , time: 0'u64, id: (hash: 0x3edd5b10'u32, next: 4370000'u64)), # First Spurious block
    (number: 4369999'u64 , time: 0'u64, id: (hash: 0x3edd5b10'u32, next: 4370000'u64)), # Last Spurious block
    (number: 4370000'u64 , time: 0'u64, id: (hash: 0xa00bc324'u32, next: 7280000'u64)), # First Byzantium block
    (number: 7279999'u64 , time: 0'u64, id: (hash: 0xa00bc324'u32, next: 7280000'u64)), # Last Byzantium block
    (number: 7280000'u64 , time: 0'u64, id: (hash: 0x668db0af'u32, next: 9069000'u64)), # First and last Constantinople, first Petersburg block
    (number: 7987396'u64 , time: 0'u64, id: (hash: 0x668db0af'u32, next: 9069000'u64)), # Past Petersburg block
    (number: 9068999'u64 , time: 0'u64, id: (hash: 0x668db0af'u32, next: 9069000'u64)), # Last Petersburg block
    (number: 9069000'u64 , time: 0'u64, id: (hash: 0x879D6E30'u32, next: 9200000'u64)), # First Istanbul block
    (number: 9199999'u64 , time: 0'u64, id: (hash: 0x879D6E30'u32, next: 9200000'u64)), # Last Istanbul block
    (number: 9200000'u64 , time: 0'u64, id: (hash: 0xE029E991'u32, next: 12244000'u64)), # First MuirGlacier block
    (number: 12243999'u64, time: 0'u64, id: (hash: 0xE029E991'u32, next: 12244000'u64)), # Last MuirGlacier block
    (number: 12244000'u64, time: 0'u64, id: (hash: 0x0eb440f6'u32, next: 12965000'u64)), # First Berlin block
    (number: 12964999'u64, time: 0'u64, id: (hash: 0x0eb440f6'u32, next: 12965000'u64)), # Last Berlin block
    (number: 12965000'u64, time: 0'u64, id: (hash: 0xb715077d'u32, next: 13773000'u64)), # First London block
    (number: 13772999'u64, time: 0'u64, id: (hash: 0xb715077d'u32, next: 13773000'u64)), # Last London block
    (number: 13773000'u64, time: 0'u64, id: (hash: 0x20c327fc'u32, next: 15050000'u64)), # First Arrow Glacier block
    (number: 15049999'u64, time: 0'u64, id: (hash: 0x20c327fc'u32, next: 15050000'u64)), # Last Arrow Glacier block
    (number: 15050000'u64, time: 0'u64, id: (hash: 0xf0afd0e3'u32, next: 1681338455'u64)), # First Gray Glacier block
    (number: 15050000'u64, time: 1681338454'u64, id: (hash: 0xf0afd0e3'u32, next: 1681338455'u64)), # Last Gray Glacier block
    (number: 15050000'u64, time: 1681338455'u64, id: (hash: 0xdce96c2d'u32, next: 1710338135'u64)), # First Shanghai time
    (number: 15050000'u64, time: 1710338134'u64, id: (hash: 0xdce96c2d'u32, next: 1710338135'u64)), # Last Shanghai time
    (number: 15050000'u64, time: 1710338135'u64, id: (hash: 0x9f3d2254'u32, next: 1746612311'u64)), # First Cancun time
    (number: 15050000'u64, time: 1746612310'u64, id: (hash: 0x9f3d2254'u32, next: 1746612311'u64)), # Last Cancun time
    (number: 15050000'u64, time: 1746612311'u64, id: (hash: 0xc376cf8b'u32, next: 1764798551'u64)), # First Prague time
    (number: 15050000'u64, time: 1764798550'u64, id: (hash: 0xc376cf8b'u32, next: 1764798551'u64)), # Last Prague time
    (number: 15050000'u64, time: 1764798551'u64, id: (hash: 0x5167e2a6'u32, next: 1765290071'u64)), # First Osaka time
    (number: 15050000'u64, time: 1765290070'u64, id: (hash: 0x5167e2a6'u32, next: 1765290071'u64)), # Last Osaka time
    (number: 15050000'u64, time: 1765290071'u64, id: (hash: 0xcba2a1c0'u32, next: 1767747671'u64)), # First BPO1 time
    (number: 15050000'u64, time: 1767747670'u64, id: (hash: 0xcba2a1c0'u32, next: 1767747671'u64)), # Last BPO1 time
    (number: 15050000'u64, time: 1767747671'u64, id: (hash: 0x07c9462e'u32, next: 0'u64)),          # First BPO2 time
    (number: 15050000'u64, time: 1767747672'u64, id: (hash: 0x07c9462e'u32, next: 0'u64)),          # Future BPO2 time
  ]

  SepoliaNetIDs = [
    (number: 0'u64,       time: 0'u64, id: (hash: 0xfe3366e7'u32, next: 1450409'u64)),             # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople, Petersburg, Istanbul, Berlin and first London block
    (number: 1450408'u64, time: 0'u64, id: (hash: 0xfe3366e7'u32, next: 1450409'u64)),             # Last London block
    (number: 1450409'u64, time: 0'u64, id: (hash: 0x4a85c09c'u32, next: 1677557088'u64)),          # First MergeNetsplit block
    (number: 1450410'u64, time: 1677557087'u64, id: (hash: 0x4a85c09c'u32, next: 1677557088'u64)), # Last MergeNetsplit block
    (number: 1450410'u64, time: 1677557088'u64, id: (hash: 0xce82fa52'u32, next: 1706655072'u64)), # First Shanghai time
    (number: 1450410'u64, time: 1706655071'u64, id: (hash: 0xce82fa52'u32, next: 1706655072'u64)), # Last Shanghai time
    (number: 1450410'u64, time: 1706655072'u64, id: (hash: 0xa6260961'u32, next: 1741159776'u64)), # First Cancun time
    (number: 1450410'u64, time: 1741159775'u64, id: (hash: 0xa6260961'u32, next: 1741159776'u64)), # Last Cancun time
    (number: 1450410'u64, time: 1741159776'u64, id: (hash: 0x1cd80755'u32, next: 1760427360'u64)), # First Prague time
    (number: 1450410'u64, time: 1760427359'u64, id: (hash: 0x1cd80755'u32, next: 1760427360'u64)), # Last Prague time
    (number: 1450410'u64, time: 1760427360'u64, id: (hash: 0x55369A33'u32, next: 1761017184'u64)), # First Osaka time
    (number: 1450410'u64, time: 1761017183'u64, id: (hash: 0x55369A33'u32, next: 1761017184'u64)), # Last Osaka time
    (number: 1450410'u64, time: 1761017184'u64, id: (hash: 0xA47328A8'u32, next: 1761607008'u64)), # First BPO1 time
    (number: 1450410'u64, time: 1761607007'u64, id: (hash: 0xA47328A8'u32, next: 1761607008'u64)), # Last BPO1 time
    (number: 1450410'u64, time: 1761607008'u64, id: (hash: 0x4463073B'u32, next: 0'u64)),          # First BPO2 time
    (number: 1450410'u64, time: 1761607009'u64, id: (hash: 0x4463073B'u32, next: 0'u64)),          # Future BPO2 time
  ]

  HoodiNetIDs = [
    (number: 0'u64,   time: 0'u64, id: (hash: 0xBEF71D30'u32, next: 1742999832'u64)),          # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople, Petersburg, Istanbul, Berlin, London, Paris, Shanghai, Cancun block
    (number: 123'u64, time: 1742999831'u64, id: (hash: 0xBEF71D30'u32, next: 1742999832'u64)), # Last Cancun time
    (number: 123'u64, time: 1742999832'u64, id: (hash: 0x0929E24E'u32, next: 1761677592'u64)), # First Prague time
    (number: 123'u64, time: 1761677591'u64, id: (hash: 0x0929E24E'u32, next: 1761677592'u64)), # Last Prague time
    (number: 123'u64, time: 1761677592'u64, id: (hash: 0xE7E0E7FF'u32, next: 1762365720'u64)), # First Osaka time
    (number: 123'u64, time: 1762365719'u64, id: (hash: 0xE7E0E7FF'u32, next: 1762365720'u64)), # Last Osaka time
    (number: 123'u64, time: 1762365720'u64, id: (hash: 0x3893353E'u32, next: 1762955544'u64)), # First BPO1 time
    (number: 123'u64, time: 1762955543'u64, id: (hash: 0x3893353E'u32, next: 1762955544'u64)), # Last BPO1 time
    (number: 123'u64, time: 1762955544'u64, id: (hash: 0x23AA1351'u32, next: 0'u64)),          # First BPO2 time
    (number: 123'u64, time: 1762955545'u64, id: (hash: 0x23AA1351'u32, next: 0'u64)),          # Future BPO2 time
  ]

template runComputeForkIdTest(network: untyped, name: string) =
  test name & " Compute ForkId test":
    var
      params = networkParams(network)
      com    = CommonRef.new(newCoreDbRef DefaultDbMemory, network, params)

    for x in `network IDs`:
      let computedId = com.forkId(x.number, x.time)
      let expectedId = ForkId(hash: x.id.hash.to(Bytes4), next: x.id.next)
      check:
        computedId == expectedId

        # The computed ID should be compatible with the CommonRef ForkIdCalculator itself
        com.compatibleForkId(computedId, BlockNumber(x.number), EthTime(x.time)) == true
        # And also when set to current fork timestamp
        com.compatibleForkId(computedId, BlockNumber(0'u64), EthTime(1761921403'u64)) == true

      if x.time != 0'u64:
        # Only for time-based forks check also the time-only function
        let computedIdTimeOnly = com.forkId(EthTime(x.time))
        check computedIdTimeOnly == expectedId

const
  ValidationTests = [

    # from
    # https://github.com/ethereum/go-ethereum/blob/0413af40f60290cf689b4ecca4e51fef0ec11119/core/forkid/forkid_test.go#L304

    #------------------
    # Block based tests
    #------------------

    # Local is mainnet Gray Glacier, remote announces the same. No future fork is announced.
    (config: MainNet, head: 15050000'u64, time: 0'u64, id: (hash: 0xf0afd0e3'u32, next: 0'u64), compatible: true),

    # Local is mainnet Gray Glacier, remote announces the same. Remote also announces a next fork
    # at block 0xffffffff, but that is uncertain.
    (config: MainNet, head: 15050000'u64, time: 0'u64, id: (hash: 0xf0afd0e3'u32, next: uint64.high()), compatible: true),

    # Local is mainnet currently in Byzantium only (so it's aware of Petersburg), remote announces
    # also Byzantium, but it's not yet aware of Petersburg (e.g. non updated node before the fork).
    # In this case we don't know if Petersburg passed yet or not.
    (config: MainNet, head: 7279999'u64, time: 0'u64, id: (hash: 0xa00bc324'u32, next: 0'u64), compatible: true),

    # Local is mainnet currently in Byzantium only (so it's aware of Petersburg), remote announces
    # also Byzantium, and it's also aware of Petersburg (e.g. updated node before the fork). We
    # don't know if Petersburg passed yet (will pass) or not.
    (config: MainNet, head: 7279999'u64, time: 0'u64, id: (hash: 0xa00bc324'u32, next: 7280000'u64), compatible: true),

    # Local is mainnet currently in Byzantium only (so it's aware of Petersburg), remote announces
    # also Byzantium, and it's also aware of some random fork (e.g. misconfigured Petersburg). As
    # neither forks passed at neither nodes, they may mismatch, but we still connect for now.
    (config: MainNet, head: 7279999'u64, time: 0'u64, id: (hash: 0xa00bc324'u32, next: uint64.high()), compatible: true),

    # Local is mainnet exactly on Petersburg, remote announces Byzantium + knowledge about Petersburg. Remote
    # is simply out of sync, accept.
    (config: MainNet, head: 7280000'u64, time: 0'u64, id: (hash: 0xa00bc324'u32, next: 7280000'u64), compatible: true),

    # Local is mainnet Petersburg, remote announces Byzantium + knowledge about Petersburg. Remote
    # is simply out of sync, accept.
    (config: MainNet, head: 7987396'u64, time: 0'u64, id: (hash: 0xa00bc324'u32, next: 7280000'u64), compatible: true),

    # Local is mainnet Petersburg, remote announces Spurious + knowledge about Byzantium. Remote
    # is definitely out of sync. It may or may not need the Petersburg update, we don't know yet.
    (config: MainNet, head: 7987396'u64, time: 0'u64, id: (hash: 0x3edd5b10'u32, next: 4370000'u64), compatible: true),

    # Local is mainnet Byzantium, remote announces Petersburg. Local is out of sync, accept.
    (config: MainNet, head: 7279999'u64, time: 0'u64, id: (hash: 0x668db0af'u32, next: 0'u64), compatible: true),

    # Local is mainnet Spurious, remote announces Byzantium, but is not aware of Petersburg. Local
    # out of sync. Local also knows about a future fork, but that is uncertain yet.
    (config: MainNet, head: 4369999'u64, time: 0'u64, id: (hash: 0xa00bc324'u32, next: 0'u64), compatible: true),

    # Local is mainnet Petersburg. remote announces Byzantium but is not aware of further forks.
    # Remote needs software update.
    (config: MainNet, head: 7987396'u64, time: 0'u64, id: (hash: 0xa00bc324'u32, next: 0'u64), compatible: false),

    # Local is mainnet Petersburg, and isn't aware of more forks. Remote announces Petersburg +
    # 0xffffffff. Local needs software update, reject.
    (config: MainNet, head: 7987396'u64, time: 0'u64, id: (hash: 0x5cddc0e1'u32, next: 0'u64), compatible: false),

    # Local is mainnet Byzantium, and is aware of Petersburg. Remote announces Petersburg +
    # 0xffffffff. Local needs software update, reject.
    (config: MainNet, head: 7279999'u64, time: 0'u64, id: (hash: 0x5cddc0e1'u32, next: 0'u64), compatible: false),

    # Local is mainnet Petersburg, remote is Rinkeby Petersburg.
    (config: MainNet, head: 7987396'u64, time: 0'u64, id: (hash: 0xafec6b27'u32, next: 0'u64), compatible: false),

    # Local is mainnet Gray Glacier, far in the future. Remote announces Gopherium (non existing fork)
    # at some future block 88888888, for itself, but past block for local. Local is incompatible.
    #
    # This case detects non-upgraded nodes with majority hash power (typical Ropsten mess).
    # Note: disable this test as it needs to be tested with a configuration without Shanghai and later forks
    # It would turn true now because time is set to 0, and thus Paris is not considered passed yet.
    # In practise time would not get to 0.
    # (config: MainNet, head: 88888888'u64, time: 0'u64, id: (hash: 0xf0afd0e3'u32, next: 88888888'u64), compatible: false),

    # Local is mainnet Byzantium. Remote is also in Byzantium, but announces Gopherium (non existing
    # fork) at block 7279999, before Petersburg. Local is incompatible.
    (config: MainNet, head: 7279999'u64, time: 0'u64, id: (hash: 0xa00bc324'u32, next: 7279999'u64), compatible: false),

    #------------------------------------
    # Block to timestamp transition tests
    #-----------------------------------

    # Local is mainnet currently in Gray Glacier only (so it's aware of Shanghai), remote announces
    # also Gray Glacier, but it's not yet aware of Shanghai (e.g. non updated node before the fork).
    # In this case we don't know if Shanghai passed yet or not.
    (config: MainNet, head: 15050000'u64, time: 0'u64, id: (hash: 0xf0afd0e3'u32, next: 0'u64), compatible: true),

    # Local is mainnet currently in Gray Glacier only (so it's aware of Shanghai), remote announces
    # also Gray Glacier, and it's also aware of Shanghai (e.g. updated node before the fork). We
    # don't know if Shanghai passed yet (will pass) or not.
    (config: MainNet, head: 15050000'u64, time: 0'u64, id: (hash: 0xf0afd0e3'u32, next: 1681338455'u64), compatible: true),

    # Local is mainnet currently in Gray Glacier only (so it's aware of Shanghai), remote announces
    # also Gray Glacier, and it's also aware of some random fork (e.g. misconfigured Shanghai). As
    # neither forks passed at neither nodes, they may mismatch, but we still connect for now.
    (config: MainNet, head: 15050000'u64, time: 0'u64, id: (hash: 0xf0afd0e3'u32, next: uint64.high()), compatible: true),

    # Local is mainnet exactly on Shanghai, remote announces Gray Glacier + knowledge about Shanghai. Remote
    # is simply out of sync, accept.
    (config: MainNet, head: 20000000'u64, time: 1681338455'u64, id: (hash: 0xf0afd0e3'u32, next: 1681338455'u64), compatible: true),

    # Local is mainnet Shanghai, remote announces Gray Glacier + knowledge about Shanghai. Remote
    # is simply out of sync, accept.
    (config: MainNet, head: 20123456'u64, time: 1681338456'u64, id: (hash: 0xf0afd0e3'u32, next: 1681338455'u64), compatible: true),

    # Local is mainnet Shanghai, remote announces Arrow Glacier + knowledge about Gray Glacier. Remote
    # is definitely out of sync. It may or may not need the Shanghai update, we don't know yet.
    (config: MainNet, head: 20000000'u64, time: 1681338455'u64, id: (hash: 0x20c327fc'u32, next: 15050000'u64), compatible: true),

    # Local is mainnet Gray Glacier, remote announces Shanghai. Local is out of sync, accept.
    (config: MainNet, head: 15050000'u64, time: 0'u64, id: (hash: 0xdce96c2d'u32, next: 0'u64), compatible: true),

    # Local is mainnet Arrow Glacier, remote announces Gray Glacier, but is not aware of Shanghai. Local
    # out of sync. Local also knows about a future fork, but that is uncertain yet.
    (config: MainNet, head: 13773000'u64, time: 0'u64, id: (hash: 0xf0afd0e3'u32, next: 0'u64), compatible: true),

    # Local is mainnet Shanghai. remote announces Gray Glacier but is not aware of further forks.
    # Remote needs software update.
    (config: MainNet, head: 20000000'u64, time: 1681338455'u64, id: (hash: 0xf0afd0e3'u32, next: 0'u64), compatible: false),

    # Local is mainnet Gray Glacier, and isn't aware of more forks. Remote announces Gray Glacier +
    # 0xffffffff. Local needs software update, reject.
    (config: MainNet, head: 15050000'u64, time: 0'u64, id: (hash: crc32(0xf0afd0e3'u32, uint64.high().toBytesBE), next: 0'u64), compatible: false),

    # Local is mainnet Gray Glacier, and is aware of Shanghai. Remote announces Shanghai +
    # 0xffffffff. Local needs software update, reject.
    (config: MainNet, head: 15050000'u64, time: 0'u64, id: (hash: crc32(0xdce96c2d'u32, uint64.high().toBytesBE), next: 0'u64), compatible: false),

    # Local is mainnet Gray Glacier, far in the future. Remote announces Gopherium (non existing fork)
    # at some future timestamp 8888888888, for itself, but past block for local. Local is incompatible.
    # This case detects non-upgraded nodes with majority hash power (typical Ropsten mess).
    (config: MainNet, head: 888888888'u64, time: 1660000000'u64, id: (hash: 0xf0afd0e3'u32, next: 1660000000'u64), compatible: false),

    # Local is mainnet Gray Glacier. Remote is also in Gray Glacier, but announces Gopherium (non existing
    # fork) at block 7279999, before Shanghai. Local is incompatible.
    (config: MainNet, head: 19999999'u64, time: 1667999999'u64, id: (hash: 0xf0afd0e3'u32, next: 1667999999'u64), compatible: false),

    #----------------------
    # Timestamp based tests
    #----------------------

    # Local is mainnet Shanghai, remote announces the same. No future fork is announced.
    (config: MainNet, head: 1681338455'u64, time: 1681338455'u64, id: (hash: 0xdce96c2d'u32, next: 0'u64), compatible: true),

    # Local is mainnet Shanghai, remote announces the same. Remote also announces a next fork
    # at time 0xffffffff, but that is uncertain.
    (config: MainNet, head: 20000000'u64, time: 1681338455'u64, id: (hash: 0xdce96c2d'u32, next: uint64.high()), compatible: true),

    # Local is mainnet currently in Shanghai only (so it's aware of Cancun), remote announces
    # also Shanghai, but it's not yet aware of Cancun (e.g. non updated node before the fork).
    # In this case we don't know if Cancun passed yet or not.
    (config: MainNet, head: 20000000'u64, time: 1668000000'u64, id: (hash: 0xdce96c2d'u32, next: 0'u64), compatible: true),

    # Local is mainnet currently in Shanghai only (so it's aware of Cancun), remote announces
    # also Shanghai, and it's also aware of Cancun (e.g. updated node before the fork). We
    # don't know if Cancun passed yet (will pass) or not.
    (config: MainNet, head: 20000000'u64, time: 1668000000'u64, id: (hash: 0xdce96c2d'u32, next: 1710338135'u64), compatible: true),

    # Local is mainnet currently in Shanghai only (so it's aware of Cancun), remote announces
    # also Shanghai, and it's also aware of some random fork (e.g. misconfigured Cancun). As
    # neither forks passed at neither nodes, they may mismatch, but we still connect for now.
    (config: MainNet, head: 20000000'u64, time: 1668000000'u64, id: (hash: 0xdce96c2d'u32, next: uint64.high()), compatible: true),

    # Local is mainnet exactly on Cancun, remote announces Shanghai + knowledge about Cancun. Remote
    # is simply out of sync, accept.
    (config: MainNet, head: 21000000'u64, time: 1710338135'u64, id: (hash: 0xdce96c2d'u32, next: 1710338135'u64), compatible: true),

    # Local is mainnet Cancun, remote announces Shanghai + knowledge about Cancun. Remote
    # is simply out of sync, accept.
    (config: MainNet, head: 21123456'u64, time: 1710338136'u64, id: (hash: 0xdce96c2d'u32, next: 1710338135'u64), compatible: true),

    # Local is mainnet Prague, remote announces Shanghai + knowledge about Cancun. Remote
    # is definitely out of sync. It may or may not need the Prague update, we don't know yet.
    (config: MainNet, head: 0'u64, time: 0'u64, id: (hash: 0x3edd5b10'u32, next: 1710338135'u64), compatible: true),

    # Local is mainnet Shanghai, remote announces Cancun. Local is out of sync, accept.
    (config: MainNet, head: 21000000'u64, time: 1700000000'u64, id: (hash: 0x9f3d2254'u32, next: 0'u64), compatible: true),

    # Local is mainnet Shanghai, remote announces Cancun, but is not aware of Prague. Local
    # out of sync. Local also knows about a future fork, but that is uncertain yet.
    (config: MainNet, head: 21000000'u64, time: 1678000000'u64, id: (hash: 0xc376cf8b'u32, next: 0'u64), compatible: true),

    # Local is mainnet Cancun. remote announces Shanghai but is not aware of further forks.
    # Remote needs software update.
    (config: MainNet, head: 21000000'u64, time: 1710338135'u64, id: (hash: 0xdce96c2d'u32, next: 0'u64), compatible: false),

    # Local is mainnet Shanghai, and isn't aware of more forks. Remote announces Shanghai +
    # 0xffffffff. Local needs software update, reject.
    (config: MainNet, head: 20000000'u64, time: 1681338455'u64, id: (hash: crc32(0xdce96c2d'u32, uint64.high().toBytesBE), next: 0'u64), compatible: false),

    # Local is mainnet Shanghai, and is aware of Cancun. Remote announces Cancun +
    # 0xffffffff. Local needs software update, reject.
    (config: MainNet, head: 20000000'u64, time: 1668000000'u64, id: (hash: crc32(0x9f3d2254'u32, uint64.high().toBytesBE), next: 0'u64), compatible: false),

    # Local is mainnet Shanghai, remote is random Shanghai.
    (config: MainNet, head: 20000000'u64, time: 1681338455'u64, id: (hash: 0x12345678'u32, next: 0'u64), compatible: false),

    # Local is mainnet Prague, far in the future. Remote announces Gopherium (non existing fork)
    # at some future timestamp 8888888888, for itself, but past block for local. Local is incompatible.
    #
    # This case detects non-upgraded nodes with majority hash power (typical Ropsten mess).
    (config: MainNet, head: 88888888'u64, time: 8888888888'u64, id: (hash: 0xc376cf8b'u32, next: 8888888888'u64), compatible: false),

    # Local is mainnet Shanghai. Remote is also in Shanghai, but announces Gopherium (non existing
    # fork) at timestamp 1668000000, before Cancun. Local is incompatible.
    (config: MainNet, head: 20999999'u64, time: 1699999999'u64, id: (hash: 0x71147644'u32, next: 1700000000'u64), compatible: false),

  ]

proc runCompatibleForkIdTest() =
  test "Compatible ForkId validation test":
    for testcase in ValidationTests:
      var
        params = networkParams(testcase.config)
        com = CommonRef.new(newCoreDbRef DefaultDbMemory, testcase.config, params)

      let fid = ForkId(hash: testcase.id.hash.to(Bytes4), next: testcase.id.next)
      let compatible = com.compatibleForkId(fid, BlockNumber(testcase.head), EthTime(testcase.time))

      check compatible == testcase.compatible

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

func calculateForkId(conf: ChainConfig, crc: uint32, time: uint64): ForkId =
  let map = conf.toForkTransitionTable
  let calc = ForkIdCalculator.init(map, crc, time)
  calc.calculateForkId(0, time)

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
    let get = calculateForkId(x.c, genesisCRC, time)
    check get.hash == x.want.crc.to(Bytes4)
    check get.next == x.want.next

suite "ForkId tests":
  runComputeForkIdTest(MainNet, "MainNet")
  runComputeForkIdTest(SepoliaNet, "SepoliaNet")
  runComputeForkIdTest(HoodiNet, "HoodiNet")
  runCompatibleForkIdTest()
  test "Genesis Time ForkId tests":
    runGenesisTimeIdTests()
