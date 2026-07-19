# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
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
  ../../execution_chain/common,
  ../../execution_chain/conf,
  ../../execution_chain/utils/utils,
  ../../execution_chain/core/chain/forked_chain,
  ../../execution_chain/core/chain/forked_chain/chain_desc,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/ledger,
  ../../execution_chain/history/db/ere_db,
  ../../execution_chain/rpc/debug,
  ../../execution_chain/stateless/[stateless_execution, stateless_execution_helpers]

const
  sourcePath  = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
  networkId = MainNet

procSuite "Stateless Execution Tests":

  setup:
    let
      db = AristoDbMemory.newCoreDbRef()
      era0 = EreDB.new(sourcePath.parentDir / "replay", "mainnet", 15537394'u64).expect("Ere files present")
      # Stateless provider is enabled so that witnesses will be generated
      # and stored in the database
      com = CommonRef.new(db, statelessProvider = true)
      fc = ForkedChainRef.init(com, enableQueue = false)

  asyncTest "Stateless process block - replay mainnet ere":
    var blk: EthBlock
    for i in 1..<1000:
      era0.getEthBlock(i.BlockNumber, blk).expect("block in test database")
      check (await fc.importBlock(blk)).isOk()

      let witness = fc.getExecutionWitness(blk.header.computeBlockHash()).expect("ok")
      check:
        statelessProcessBlock(witness.toExecutionWitness(), com, blk).isOk()
        statelessProcessBlock(witness.toExecutionWitness(), networkId, blk).isOk()

      let
        witnessRlpBytes = witness.encode()
        blkRlpBytes = rlp.encode(blk)
      check:
        statelessProcessBlockRlp(witnessRlpBytes, com, blkRlpBytes).isOk()
        statelessProcessBlockRlp(witnessRlpBytes.to0xHex(), com, blkRlpBytes.to0xHex()).isOk()

  asyncTest "Stateless incomplete witness - fail at block-reward persist without crashing":
    # These early mainnet blocks are empty, but the block-reward persist still runs
    # in procBlkEpilogue so this runs the fatal error path caught by the abortOnFatalError.
    # Dropping the coinbase's node makes that reward persist fail. Dropping a node
    # that breaks the trie root is rejected even earlier at the witness subtrie root
    # check. Either way execution must return an error, never assert/crash on the
    # resulting partial trie.
    var blk: EthBlock
    for i in 1..100:
      era0.getEthBlock(i.BlockNumber, blk).expect("block in test database")
      check (await fc.importBlock(blk)).isOk()

    let witness =
      fc.getExecutionWitness(blk.header.computeBlockHash()).expect("ok").toExecutionWitness()

    # The complete witness validates.
    check statelessProcessBlock(witness, com, blk).isOk()

    # Every incomplete variant (one state node dropped) is rejected with an error
    # and never crashes.
    check witness.state.len() > 0
    for dropIdx in 0 ..< witness.state.len():
      var partial = witness
      partial.state.asSeq.delete(dropIdx)
      check statelessProcessBlock(partial, com, blk).isErr()

  asyncTest "Stateless process block json files - mainnet block 100":
    let
      witnessJsonFile = sourcePath / "mainnet_100_witness.json"
      blkJsonFile = sourcePath / "mainnet_100_block.json"
    check statelessProcessBlockJsonFiles(witnessJsonFile, com, blkJsonFile).isOk()

    let com2 = CommonRef.new(
      db = nil,
      config = chainConfigForNetwork(networkId),
      networkId = networkId,
      initializeDb = false
    )
    check statelessProcessBlockJsonFiles(witnessJsonFile, com2, blkJsonFile).isOk()
    discard era0
    discard fc

  asyncTest "Stateless process block json files - mainnet block 73141":
    let
      witnessJsonFile = sourcePath / "mainnet_73141_witness.json"
      blkJsonFile = sourcePath / "mainnet_73141_block.json"
    check statelessProcessBlockJsonFiles(witnessJsonFile, com, blkJsonFile).isOk()

    let com2 = CommonRef.new(
      db = nil,
      config = chainConfigForNetwork(networkId),
      networkId = networkId,
      initializeDb = false
    )
    check statelessProcessBlockJsonFiles(witnessJsonFile, com2, blkJsonFile).isOk()
    discard era0
    discard fc
