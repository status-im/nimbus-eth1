# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
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
  ../nimbus/config,
  ../nimbus/common/common

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

proc makeGenesis(networkId: NetworkId): BlockHeader =
  let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = networkParams(networkId))
  com.genesisHeader

proc genesisTest() =
  suite "Genesis":
    test "Correct mainnet hash":
      let b = makeGenesis(MainNet)
      check(b.blockHash == "D4E56740F876AEF8C010B86A40D5F56745A118D0906A34E69AEC8C0DB1CB8FA3".toDigest)

    test "Correct goerlinet hash":
      let b = makeGenesis(GoerliNet)
      check(b.blockHash == "bf7e331f7f7c1dd2e05159666b3bf8bc7a8a3a9eb1d518969eab529dd9b88c1a".toDigest)

    test "Correct sepolia hash":
      let b = makeGenesis(SepoliaNet)
      check b.blockHash == "25a5cc106eea7138acab33231d7160d69cb777ee0c2c553fcddf5138993e6dd9".toDigest

    test "Correct holesky hash":
      let b = makeGenesis(HoleskyNet)
      check b.blockHash == "b5f7f912443c940f21fd611f12828d75b534364ed9e95ca4e307729a4661bde4".toDigest
      check b.stateRoot == "69D8C9D72F6FA4AD42D4702B433707212F90DB395EB54DC20BC85DE253788783".toDigest

proc customGenesisTest() =
  suite "Custom Genesis":
    test "loadCustomGenesis":
      var cga, cgb, cgc: NetworkParams
      check loadNetworkParams("berlin2000.json".findFilePath, cga)
      check loadNetworkParams("chainid7.json".findFilePath, cgb)
      check loadNetworkParams("noconfig.json".findFilePath, cgc)
      check cga.config.consensusType == ConsensusType.POW
      check cgb.config.consensusType == ConsensusType.POW
      check cgc.config.consensusType == ConsensusType.POW

    test "calaveras.json":
      var cg: NetworkParams
      check loadNetworkParams("calaveras.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = "664c93de37eb4a72953ea42b8c046cdb64c9f0b0bca5505ade8d970d49ebdb8c".toDigest
      let genesisHash = "eb9233d066c275efcdfed8037f4fc082770176aefdbcb7691c71da412a5670f2".toDigest
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.consensus == ConsensusType.POA
      check com.cliquePeriod == 30
      check com.cliqueEpoch == 30000

    test "Devnet4.json (aka Kintsugi in all but chainId)":
      var cg: NetworkParams
      check loadNetworkParams("devnet4.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = "3b84f313bfd49c03cc94729ade2e0de220688f813c0c895a99bd46ecc9f45e1e".toDigest
      let genesisHash = "a28d8d73e087a01d09d8cb806f60863652f30b6b6dfa4e0157501ff07d422399".toDigest
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.consensus == ConsensusType.POW

    test "Devnet5.json (aka Kiln in all but chainId and TTD)":
      var cg: NetworkParams
      check loadNetworkParams("devnet5.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = "52e628c7f35996ba5a0402d02b34535993c89ff7fc4c430b2763ada8554bee62".toDigest
      let genesisHash = "51c7fe41be669f69c45c33a56982cbde405313342d9e2b00d7c91a7b284dd4f8".toDigest
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.consensus == ConsensusType.POW

    test "Mainnet shadow fork 1":
      var cg: NetworkParams
      check loadNetworkParams("mainshadow1.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = "d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544".toDigest
      let genesisHash = "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3".toDigest
      let ttd = "46_089_003_871_917_200_000_000".parse(Uint256)
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.ttd.get == ttd
      check com.consensus == ConsensusType.POW

    test "Geth shadow fork 1":
      # parse using geth format should produce the same result with nimbus format
      var cg: NetworkParams
      check loadNetworkParams("geth_mainshadow1.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = "d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544".toDigest
      let genesisHash = "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3".toDigest
      let ttd = "46_089_003_871_917_200_000_000".parse(Uint256)
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.ttd.get == ttd
      check com.consensus == ConsensusType.POW
      check cg.config.mergeNetsplitBlock.isSome
      check cg.config.mergeNetsplitBlock.get == 14660963.toBlockNumber
      check cg.config.mergeNetsplitBlock == cg.config.mergeForkBlock

    test "Holesky":
      var cg: NetworkParams
      check loadNetworkParams("holesky.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = "69D8C9D72F6FA4AD42D4702B433707212F90DB395EB54DC20BC85DE253788783".toDigest
      let genesisHash = "b5f7f912443c940f21fd611f12828d75b534364ed9e95ca4e307729a4661bde4".toDigest
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.chainId == 17000.ChainId

    test "Geth Holesky":
      # parse using geth format should produce the same result with nimbus format
      var cg: NetworkParams
      check loadNetworkParams("geth_holesky.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = "69D8C9D72F6FA4AD42D4702B433707212F90DB395EB54DC20BC85DE253788783".toDigest
      let genesisHash = "b5f7f912443c940f21fd611f12828d75b534364ed9e95ca4e307729a4661bde4".toDigest
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.chainId == 17000.ChainId

proc genesisMain*() =
  genesisTest()
  customGenesisTest()

when isMainModule:
  genesisTest()
  customGenesisTest()
