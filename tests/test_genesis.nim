import
  std/[os],
  unittest2, eth/common,
  ../nimbus/[genesis, config, chain_config]

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

proc genesisTest() =
  suite "Genesis":
    test "Correct mainnet hash":
      let b = networkParams(MainNet).toGenesisHeader
      check(b.blockHash == "D4E56740F876AEF8C010B86A40D5F56745A118D0906A34E69AEC8C0DB1CB8FA3".toDigest)

    test "Correct ropstennet hash":
      let b = networkParams(RopstenNet).toGenesisHeader
      check(b.blockHash == "41941023680923e0fe4d74a34bdac8141f2540e3ae90623718e47d66d1ca4a2d".toDigest)

    test "Correct rinkebynet hash":
      let b = networkParams(RinkebyNet).toGenesisHeader
      check(b.blockHash == "6341fd3daf94b748c72ced5a5b26028f2474f5f00d824504e4fa37a75767e177".toDigest)

    test "Correct goerlinet hash":
      let b = networkParams(GoerliNet).toGenesisHeader
      check(b.blockHash == "bf7e331f7f7c1dd2e05159666b3bf8bc7a8a3a9eb1d518969eab529dd9b88c1a".toDigest)

    test "Correct sepolia hash":
      let b = networkParams(SepoliaNet).toGenesisHeader
      check b.blockHash == "25a5cc106eea7138acab33231d7160d69cb777ee0c2c553fcddf5138993e6dd9".toDigest

proc customGenesisTest() =
  suite "Custom Genesis":
    test "loadCustomGenesis":
      var cga, cgb, cgc: NetworkParams
      check loadNetworkParams("berlin2000.json".findFilePath, cga)
      check loadNetworkParams("chainid7.json".findFilePath, cgb)
      check loadNetworkParams("noconfig.json".findFilePath, cgc)
      check cga.config.poaEngine == false
      check cgb.config.poaEngine == false
      check cgc.config.poaEngine == false

    test "calaveras.json":
      var cg: NetworkParams
      check loadNetworkParams("calaveras.json".findFilePath, cg)
      let h = cg.toGenesisHeader
      let stateRoot = "664c93de37eb4a72953ea42b8c046cdb64c9f0b0bca5505ade8d970d49ebdb8c".toDigest
      let genesisHash = "eb9233d066c275efcdfed8037f4fc082770176aefdbcb7691c71da412a5670f2".toDigest
      check h.stateRoot == stateRoot
      check h.blockHash == genesisHash
      check cg.config.poaEngine == true
      check cg.config.cliquePeriod == 30
      check cg.config.cliqueEpoch == 30000

    test "Devnet4.json (aka Kintsugi in all but chainId)":
      var cg: NetworkParams
      check loadNetworkParams("devnet4.json".findFilePath, cg)
      let h = cg.toGenesisHeader
      let stateRoot = "3b84f313bfd49c03cc94729ade2e0de220688f813c0c895a99bd46ecc9f45e1e".toDigest
      let genesisHash = "a28d8d73e087a01d09d8cb806f60863652f30b6b6dfa4e0157501ff07d422399".toDigest
      check h.stateRoot == stateRoot
      check h.blockHash == genesisHash
      check cg.config.poaEngine == false

    test "Devnet5.json (aka Kiln in all but chainId and TTD)":
      var cg: NetworkParams
      check loadNetworkParams("devnet5.json".findFilePath, cg)
      let h = cg.toGenesisHeader
      let stateRoot = "52e628c7f35996ba5a0402d02b34535993c89ff7fc4c430b2763ada8554bee62".toDigest
      let genesisHash = "51c7fe41be669f69c45c33a56982cbde405313342d9e2b00d7c91a7b284dd4f8".toDigest
      check h.stateRoot == stateRoot
      check h.blockHash == genesisHash
      check cg.config.poaEngine == false

    test "Mainnet shadow fork 1":
      var cg: NetworkParams
      check loadNetworkParams("mainshadow1.json".findFilePath, cg)
      let h = cg.toGenesisHeader
      let stateRoot = "d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544".toDigest
      let genesisHash = "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3".toDigest
      let ttd = "46_089_003_871_917_200_000_000".parse(Uint256)
      check h.stateRoot == stateRoot
      check h.blockHash == genesisHash
      check cg.config.terminalTotalDifficulty.get == ttd
      check cg.config.poaEngine == false

proc genesisMain*() =
  genesisTest()
  customGenesisTest()

when isMainModule:
  genesisTest()
  customGenesisTest()
