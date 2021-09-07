import
  std/[os],
  unittest2, eth/common, nimcrypto/hash,
  ../nimbus/[genesis, config, chain_config]

const dataFolder = "tests" / "customgenesis"

proc genesisTest() =
  suite "Genesis":
    test "Correct mainnet hash":
      let g = genesisBlockForNetwork(MainNet, CustomNetwork())
      let b = g.toBlock
      check(b.blockHash == "D4E56740F876AEF8C010B86A40D5F56745A118D0906A34E69AEC8C0DB1CB8FA3".toDigest)

    test "Correct ropstennet hash":
      let g = genesisBlockForNetwork(RopstenNet, CustomNetwork())
      let b = g.toBlock
      check(b.blockHash == "41941023680923e0fe4d74a34bdac8141f2540e3ae90623718e47d66d1ca4a2d".toDigest)

    test "Correct rinkebynet hash":
      let g = genesisBlockForNetwork(RinkebyNet, CustomNetwork())
      let b = g.toBlock
      check(b.blockHash == "6341fd3daf94b748c72ced5a5b26028f2474f5f00d824504e4fa37a75767e177".toDigest)

    test "Correct goerlinet hash":
      let g = genesisBlockForNetwork(GoerliNet, CustomNetwork())
      let b = g.toBlock
      check(b.blockHash == "bf7e331f7f7c1dd2e05159666b3bf8bc7a8a3a9eb1d518969eab529dd9b88c1a".toDigest)

proc customGenesisTest() =
  suite "Custom Genesis":
    test "loadCustomGenesis":
      var cga, cgb, cgc: CustomNetwork
      check loadCustomNetwork(dataFolder / "berlin2000.json", cga)
      check loadCustomNetwork(dataFolder / "chainid7.json", cgb)
      check loadCustomNetwork(dataFolder / "noconfig.json", cgc)
      check cga.config.poaEngine == false
      check cgb.config.poaEngine == false
      check cgc.config.poaEngine == false

    test "calaveras.json":
      var cg: CustomNetwork
      check loadCustomNetwork(dataFolder / "calaveras.json", cg)
      let h = toBlock(cg.genesis, nil)
      let stateRoot = "664c93de37eb4a72953ea42b8c046cdb64c9f0b0bca5505ade8d970d49ebdb8c".toDigest
      let genesisHash = "eb9233d066c275efcdfed8037f4fc082770176aefdbcb7691c71da412a5670f2".toDigest
      check h.stateRoot == stateRoot
      check h.blockHash == genesisHash
      check cg.config.poaEngine == true
      check cg.config.cliquePeriod == 30
      check cg.config.cliqueEpoch == 30000

proc genesisMain*() =
  genesisTest()
  customGenesisTest()

when isMainModule:
  genesisMain()
