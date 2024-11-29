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
  ../nimbus/common/common,
  ../nimbus/utils/utils

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
  let com = CommonRef.new(newCoreDbRef DefaultDbMemory,
    networkId = params.config.chainId.NetworkId,
    params = params)
  let header = com.genesisHeader
  com.proofOfStake(header)

proc genesisTest() =
  suite "Genesis":
    test "Correct mainnet hash":
      let b = makeGenesis(MainNet)
      check(b.blockHash == hash32"D4E56740F876AEF8C010B86A40D5F56745A118D0906A34E69AEC8C0DB1CB8FA3")

    test "Correct sepolia hash":
      let b = makeGenesis(SepoliaNet)
      check b.blockHash == hash32"25a5cc106eea7138acab33231d7160d69cb777ee0c2c553fcddf5138993e6dd9"

    test "Correct holesky hash":
      let b = makeGenesis(HoleskyNet)
      check b.blockHash == hash32"b5f7f912443c940f21fd611f12828d75b534364ed9e95ca4e307729a4661bde4"
      check b.stateRoot == hash32"69D8C9D72F6FA4AD42D4702B433707212F90DB395EB54DC20BC85DE253788783"

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
      check com.genesisHeader.blockHash == genesisHash
      check com.proofOfStake(com.genesisHeader) == false

    test "Devnet5.json (aka Kiln in all but chainId and TTD)":
      var cg: NetworkParams
      check loadNetworkParams("devnet5.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"52e628c7f35996ba5a0402d02b34535993c89ff7fc4c430b2763ada8554bee62"
      let genesisHash = hash32"51c7fe41be669f69c45c33a56982cbde405313342d9e2b00d7c91a7b284dd4f8"
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.proofOfStake(com.genesisHeader) == false

    test "Mainnet shadow fork 1":
      var cg: NetworkParams
      check loadNetworkParams("mainshadow1.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"
      let genesisHash = hash32"d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      let ttd = "46_089_003_871_917_200_000_000".parse(UInt256)
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.ttd.get == ttd
      check com.proofOfStake(com.genesisHeader) == false

    test "Geth shadow fork 1":
      # parse using geth format should produce the same result with nimbus format
      var cg: NetworkParams
      check loadNetworkParams("geth_mainshadow1.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"
      let genesisHash = hash32"d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3"
      let ttd = "46_089_003_871_917_200_000_000".parse(UInt256)
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.ttd.get == ttd
      check com.proofOfStake(com.genesisHeader) == false
      check cg.config.mergeNetsplitBlock.isSome
      check cg.config.mergeNetsplitBlock.get == 14660963.BlockNumber
      check cg.config.mergeNetsplitBlock == cg.config.mergeForkBlock

    test "Holesky":
      var cg: NetworkParams
      check loadNetworkParams("holesky.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"69D8C9D72F6FA4AD42D4702B433707212F90DB395EB54DC20BC85DE253788783"
      let genesisHash = hash32"b5f7f912443c940f21fd611f12828d75b534364ed9e95ca4e307729a4661bde4"
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.chainId == 17000.ChainId

    test "Geth Holesky":
      # parse using geth format should produce the same result with nimbus format
      var cg: NetworkParams
      check loadNetworkParams("geth_holesky.json".findFilePath, cg)
      let com = CommonRef.new(newCoreDbRef DefaultDbMemory, params = cg)
      let stateRoot = hash32"69D8C9D72F6FA4AD42D4702B433707212F90DB395EB54DC20BC85DE253788783"
      let genesisHash = hash32"b5f7f912443c940f21fd611f12828d75b534364ed9e95ca4e307729a4661bde4"
      check com.genesisHeader.stateRoot == stateRoot
      check com.genesisHeader.blockHash == genesisHash
      check com.chainId == 17000.ChainId

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
      check calcRequestsHash(default(seq[byte]), default(seq[byte]), default(seq[byte])) == EmptyRequestsHash

proc genesisMain*() =
  genesisTest()
  customGenesisTest()

when isMainModule:
  genesisTest()
  customGenesisTest()
