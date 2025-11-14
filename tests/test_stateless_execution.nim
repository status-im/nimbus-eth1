# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  chronos,
  unittest2,
  testutils,
  std/[os, strutils],
  stew/byteutils,
  ../execution_chain/common,
  ../execution_chain/conf,
  ../execution_chain/utils/utils,
  ../execution_chain/core/chain/forked_chain,
  ../execution_chain/core/chain/forked_chain/chain_desc,
  ../execution_chain/db/ledger,
  ../execution_chain/db/era1_db,
  ../execution_chain/rpc/debug,
  ../execution_chain/stateless/[stateless_execution, stateless_execution_helpers]

const
  sourcePath  = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
  networkId = MainNet

procSuite "Stateless Execution Tests":

  setup:
    let
      db = AristoDbMemory.newCoreDbRef()
      era0 = Era1DbRef.init(sourcePath / "replay", "mainnet", 15537394'u64).expect("Era files present")
      # Stateless provider is enabled so that witnesses will be generated
      # and stored in the database
      com = CommonRef.new(db, nil, statelessProviderEnabled = true)
      fc = ForkedChainRef.init(com, enableQueue = false)

  asyncTest "Stateless process block - replay mainnet era1":
    var blk: EthBlock
    for i in 1..<1000:
      era0.getEthBlock(i.BlockNumber, blk).expect("block in test database")
      check (await fc.importBlock(blk)).isOk()

      let witness = fc.getExecutionWitness(blk.header.computeBlockHash()).expect("ok")
      check:
        statelessProcessBlock(witness, com, blk).isOk()
        statelessProcessBlock(witness, networkId, blk).isOk()

      let
        witnessRlpBytes = witness.encode()
        blkRlpBytes = rlp.encode(blk)
      check:
        statelessProcessBlockRlp(witnessRlpBytes, com, blkRlpBytes).isOk()
        statelessProcessBlockRlp(witnessRlpBytes.to0xHex(), com, blkRlpBytes.to0xHex()).isOk()

  asyncTest "Stateless process block json files - mainnet block 100":
    let
      witnessJsonFile = sourcePath / "stateless" / "mainnet_100_witness.json"
      blkJsonFile = sourcePath / "stateless" / "mainnet_100_block.json"
    check statelessProcessBlockJsonFiles(witnessJsonFile, com, blkJsonFile).isOk()

    let com2 = CommonRef.new(
      db = nil,
      taskpool = nil,
      config = chainConfigForNetwork(networkId),
      networkId = networkId,
      initializeDb = false
    )
    check statelessProcessBlockJsonFiles(witnessJsonFile, com2, blkJsonFile).isOk()

  asyncTest "Stateless process block json files - mainnet block 73141":
    let
      witnessJsonFile = sourcePath / "stateless" / "mainnet_73141_witness.json"
      blkJsonFile = sourcePath / "stateless" / "mainnet_73141_block.json"
    check statelessProcessBlockJsonFiles(witnessJsonFile, com, blkJsonFile).isOk()

    let com2 = CommonRef.new(
      db = nil,
      taskpool = nil,
      config = chainConfigForNetwork(networkId),
      networkId = networkId,
      initializeDb = false
    )
    check statelessProcessBlockJsonFiles(witnessJsonFile, com2, blkJsonFile).isOk()
