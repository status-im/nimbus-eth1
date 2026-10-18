# Nimbus
# Copyright (c) 2019-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os],
  unittest2,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/utils/utils,
  ../execution_chain/common/chain_config_loader,
  ../execution_chain/common/genesis,
  ../execution_chain/common/common

const
  baseDir = [".", "tests", ".."/"tests", $DirSep]  # path containg repo
  repoDir = [".", "customgenesis"]                 # alternative repo paths

proc findFilePath(file: string): string =
  result = "?unknown?" / file
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return path

proc makeGenesis(networkId: NetworkId): Header =
  let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = networkParams(networkId))
  com.genesisHeader

proc proofOfStake(params: NetworkParams): bool =
  let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params)
  let header = com.genesisHeader
  com.proofOfStake(header, com.db.baseTxFrame())

proc genesisTest() =
  suite "Genesis":
    test "Correct mainnet hash":
      let b = makeGenesis(MainNet)
      check(b.computeBlockHash == hash32"D4E56740F876AEF8C010B86A40D5F56745A118D0906A34E69AEC8C0DB1CB8FA3")

    test "Correct sepolia hash":
      let b = makeGenesis(SepoliaNet)
      check b.computeBlockHash == hash32"25a5cc106eea7138acab33231d7160d69cb777ee0c2c553fcddf5138993e6dd9"

    test "Correct hoodi hash":
      let b = makeGenesis(HoodiNet)
      check b.computeBlockHash == hash32"bbe312868b376a3001692a646dd2d7d1e4406380dfd86b98aa8a34d1557c971b"
      check b.stateRoot == hash32"da87d7f5f91c51508791bbcbd4aa5baf04917830b86985eeb9ad3d5bfb657576"

proc customGenesisTest() =
  suite "Custom Genesis":
    test "loadCustomGenesis":
      var cga, cgb, cgc: NetworkParams
      check loadNetworkParams("berlin2000.json".findFilePath, cga)
      check loadNetworkParams("chainid7.json".findFilePath, cgb)
      check loadNetworkParams("noconfig.json".findFilePath, cgc)
      check cga.proofOfStake() == false
      check cgb.proofOfStake() == false
      check cgc.proofOfStake() == false

    test "Devnet4.json (aka Kintsugi in all but chainId)":
      var cg: NetworkParams
      check loadNetworkParams("devnet4.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"3b84f313bfd49c03cc94729ade2e0de220688f813c0c895a99bd46ecc9f45e1e"
      let genesisHash = hash32"a28d8d73e087a01d09d8cb806f60863652f30b6b6dfa4e0157501ff07d422399"
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.computeBlockHash == genesisHash
      check com.proofOfStake(com.genesisHeader, com.db.baseTxFrame()) == false

    test "Devnet5.json (aka Kiln in all but chainId and TTD)":
      var cg: NetworkParams
      check loadNetworkParams("devnet5.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"52e628c7f35996ba5a0402d02b34535993c89ff7fc4c430b2763ada8554bee62"
      let genesisHash = hash32"51c7fe41be669f69c45c33a56982cbde405313342d9e2b00d7c91a7b284dd4f8"
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.computeBlockHash == genesisHash
      check com.proofOfStake(com.genesisHeader, com.db.baseTxFrame()) == false

    test "Mainnet shadow fork 1":
      var cg: NetworkParams
      check loadNetworkParams("mainshadow1.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"
      let genesisHash = hash32"d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      let ttd = "46_089_003_871_917_200_000_000".parse(UInt256)
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.computeBlockHash == genesisHash
      check com.ttd.get == ttd
      check com.proofOfStake(com.genesisHeader, com.db.baseTxFrame()) == false

    test "Geth shadow fork 1":
      # parse using geth format should produce the same result with nimbus format
      var cg: NetworkParams
      check loadNetworkParams("geth_mainshadow1.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"
      let genesisHash = hash32"d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      let ttd = "46_089_003_871_917_200_000_000".parse(UInt256)
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.computeBlockHash == genesisHash
      check com.ttd.get == ttd
      check com.proofOfStake(com.genesisHeader, com.db.baseTxFrame()) == false
      check cg.config.mergeNetsplitBlock.isSome
      check cg.config.mergeNetsplitBlock.get == 14660963.BlockNumber

    test "Prague genesis":
      # pre Prague
      var cg: NetworkParams
      check loadNetworkParams("mekong.json".findFilePath, cg)
      var com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      check com.genesisHeader.requestsHash.isNone

      # post prague
      const EmptyRequestsHash = hash32"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      check loadNetworkParams("prague.json".findFilePath, cg)
      com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      check com.genesisHeader.requestsHash.isSome
      check com.genesisHeader.requestsHash.get == EmptyRequestsHash
      check calcRequestsHash([
        (DEPOSIT_REQUEST_TYPE, default(seq[byte])),
        (WITHDRAWAL_REQUEST_TYPE, default(seq[byte])),
        (CONSOLIDATION_REQUEST_TYPE, default(seq[byte]))
      ]) == EmptyRequestsHash

    test "BlobSchedule":
      template validateBlobSchedule(cg, fork, tgt, mx, fee) =
        check cg.config.blobSchedule[fork].isSome
        if cg.config.blobSchedule[fork].isSome:
          let bs = cg.config.blobSchedule[fork].get
          check bs.target == tgt
          check bs.max == mx
          check bs.baseFeeUpdateFraction == fee

      var cg: NetworkParams
      check loadNetworkParams("blobschedule_cancun_prague.json".findFilePath, cg)
      validateBlobSchedule(cg, Cancun, 3, 6, 3338477)
      validateBlobSchedule(cg, Prague, 6, 9, 5007716)
      validateBlobSchedule(cg, Osaka, 6, 9, 5007716)

      check loadNetworkParams("blobschedule_cancun_osaka.json".findFilePath, cg)
      validateBlobSchedule(cg, Cancun, 3, 6, 3338477)
      validateBlobSchedule(cg, Prague, 3, 6, 3338477)
      validateBlobSchedule(cg, Osaka, 6, 9, 5007716)

      check loadNetworkParams("blobschedule_prague.json".findFilePath, cg)
      validateBlobSchedule(cg, Cancun, 3, 6, 3338477) # default fallback case
      validateBlobSchedule(cg, Prague, 6, 9, 5007716)
      validateBlobSchedule(cg, Osaka, 6, 9, 5007716)

      check loadNetworkParams("blobschedule_nobasefee.json".findFilePath, cg)
      validateBlobSchedule(cg, Cancun, 3, 6, 3338477)
      validateBlobSchedule(cg, Prague, 6, 9, 3338477)
      validateBlobSchedule(cg, Osaka, 6, 9, 3338477)

      check loadNetworkParams("blobschedule_bpo.json".findFilePath, cg)
      validateBlobSchedule(cg, Cancun, 3, 6, 3338477)
      validateBlobSchedule(cg, Prague, 6, 9, 5007716)
      validateBlobSchedule(cg, Osaka, 6, 9, 5007716)
      validateBlobSchedule(cg, Bpo1, 9, 12, 5007716)
      validateBlobSchedule(cg, Bpo2, 12, 15, 5007716)
      validateBlobSchedule(cg, Bpo3, 15, 18, 5007716)
      validateBlobSchedule(cg, Bpo4, 6, 9, 5007716)
      validateBlobSchedule(cg, Bpo5, 15, 20, 5007716)

      check loadNetworkParams("blobschedule_amsterdam_fallback.json".findFilePath, cg)
      validateBlobSchedule(cg, Cancun, 3, 6, 3338477)
      validateBlobSchedule(cg, Prague, 6, 9, 5007716)
      validateBlobSchedule(cg, Osaka, 6, 9, 5007716) # fallback to Prague
      validateBlobSchedule(cg, Bpo1, 9, 12, 5008888)
      validateBlobSchedule(cg, Amsterdam, 9, 12, 5008888) # fallback to bpo1, not Bpo2

    test "BPO forks may activate after Amsterdam":
      # Shaped like the hive genesis: everything up to bpo2 at genesis and a
      # blob schedule per BPO, but none for Amsterdam.
      proc hiveParams(forkTimes: string, params: var NetworkParams): bool =
        decodeNetworkParams("""{"config": {
          "chainId": 1, "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0,
          "eip158Block": 0, "byzantiumBlock": 0, "constantinopleBlock": 0,
          "petersburgBlock": 0, "istanbulBlock": 0, "berlinBlock": 0,
          "londonBlock": 0, "mergeNetsplitBlock": 0, "terminalTotalDifficulty": 0,
          "shanghaiTime": 0, "cancunTime": 0, "pragueTime": 0, """ & forkTimes & """,
          "blobSchedule": {
            "cancun": {"target": 3, "max": 6, "baseFeeUpdateFraction": 3338477},
            "prague": {"target": 6, "max": 9, "baseFeeUpdateFraction": 5007716},
            "osaka": {"target": 6, "max": 9, "baseFeeUpdateFraction": 5007716},
            "bpo1": {"target": 10, "max": 15, "baseFeeUpdateFraction": 8346193},
            "bpo2": {"target": 14, "max": 21, "baseFeeUpdateFraction": 11684671},
            "bpo3": {"target": 21, "max": 32, "baseFeeUpdateFraction": 20609697},
            "bpo4": {"target": 28, "max": 42, "baseFeeUpdateFraction": 27479596}
          }}}""", params)

      template checkForkAt(com: CommonRef, time: uint64, hardFork: HardFork,
                           tgt, mx, fraction: uint64) =
        let
          t = EthTime(time)
          blobFork = com.toBlobFork(t)
        check com.toHardFork(t) == hardFork
        check com.toEVMFork(t) == ToEVMFork[hardFork]
        check com.isAmsterdamOrLater(t) == (hardFork >= Amsterdam)
        check com.targetBlobsPerBlock(blobFork) == tgt
        check com.maxBlobsPerBlock(blobFork) == mx
        check com.baseFeeUpdateFraction(blobFork) == fraction

      const
        osakaToBpo2 = """"osakaTime": 0, "bpo1Time": 0, "bpo2Time": 0"""
        bpo2 = (14'u64, 21'u64, 11684671'u64)
        bpo3 = (21'u64, 32'u64, 20609697'u64)
        bpo4 = (28'u64, 42'u64, 27479596'u64)

      var cg: NetworkParams

      # bpo3 after Osaka, no Amsterdam
      check hiveParams(osakaToBpo2 & """, "bpo3Time": 15000""", cg)
      var com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      com.checkForkAt(0, Bpo2, bpo2[0], bpo2[1], bpo2[2])
      com.checkForkAt(15000, Bpo3, bpo3[0], bpo3[1], bpo3[2])

      # Amsterdam and bpo3 at genesis
      check hiveParams(osakaToBpo2 &
        """, "amsterdamTime": 0, "bpo3Time": 0""", cg)
      com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      com.checkForkAt(0, Amsterdam, bpo3[0], bpo3[1], bpo3[2])
      com.checkForkAt(15000, Amsterdam, bpo3[0], bpo3[1], bpo3[2])

      # bpo3 after Amsterdam
      check hiveParams(osakaToBpo2 &
        """, "amsterdamTime": 0, "bpo3Time": 15000""", cg)
      com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      com.checkForkAt(0, Amsterdam, bpo2[0], bpo2[1], bpo2[2])
      com.checkForkAt(15000, Amsterdam, bpo3[0], bpo3[1], bpo3[2])

      # bpo4 after Amsterdam
      check hiveParams(osakaToBpo2 &
        """, "amsterdamTime": 0, "bpo3Time": 0, "bpo4Time": 15000""", cg)
      com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      com.checkForkAt(0, Amsterdam, bpo3[0], bpo3[1], bpo3[2])
      com.checkForkAt(15000, Amsterdam, bpo4[0], bpo4[1], bpo4[2])

      # BPO forks are still ordered after Osaka and among themselves, and
      # named forks among themselves
      check not hiveParams(""""osakaTime": 100, "bpo1Time": 50""", cg)
      check not hiveParams(osakaToBpo2 &
        """, "amsterdamTime": 0, "bpo3Time": 200, "bpo4Time": 100""", cg)
      check not hiveParams(osakaToBpo2 &
        """, "amsterdamTime": 200, "bogotaTime": 100""", cg)

  test "Amsterdam-slotnumber":
    var cg: NetworkParams
    check loadNetworkParams("amsterdam_slotnumber.json".findFilePath, cg)
    var com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
    check com.genesisHash == hash32"0x3d2eaa7c142566aeb179c206774b2ad1f67acab937a2119efc54d170fb52b72d"

proc genesisBlockHashTest() =
  suite "Genesis block hash":
    test "Built-in networks match the header written to the database":
      for networkId in [MainNet, SepoliaNet, HoodiNet]:
        let params = networkParams(networkId)
        check params.genesisBlockHash() == makeGenesis(networkId).computeBlockHash

    test "Custom networks match the header written to the database":
      const files = [
        "berlin2000.json", "chainid7.json", "noconfig.json", "devnet4.json",
        "devnet5.json", "mainshadow1.json", "mekong.json", "prague.json"]

      for file in files:
        var cg: NetworkParams
        check loadNetworkParams(file.findFilePath, cg)
        let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
        check cg.genesisBlockHash() == com.genesisHeader.computeBlockHash

proc genesisMain() =
  genesisTest()
  customGenesisTest()
  genesisBlockHashTest()

genesisMain()
