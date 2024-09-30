# fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  stew/byteutils,
  results,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/forks,
  ../../network/beacon/[beacon_chain_historical_summaries, beacon_content],
  ../../eth_data/yaml_utils

type YamlHistoricalSummariesWithProof* = object
  content_key*: string
  content_value*: string
  beacon_state_root*: string
  historical_summaries_root*: string
  historical_summaries_state_proof*: array[5, string]
  epoch*: uint64

suite "Beacon Chain Historical Summaries With Proof - Test Vectors":
  const testVectorDir =
    "./vendor/portal-spec-tests/tests/mainnet/beacon_chain/historical_summaries_with_proof/deneb/"

  let
    metadata = getMetadataForNetwork("mainnet")
    genesisState =
      try:
        template genesisData(): auto =
          metadata.genesis.bakedBytes

        newClone(
          readSszForkedHashedBeaconState(
            metadata.cfg, genesisData.toOpenArray(genesisData.low, genesisData.high)
          )
        )
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    # Although the test data is generated from a test state, we need to use the
    # forkDigests of mainnet as apparently these are used in the generated test vector.
    genesis_validators_root = getStateField(genesisState[], genesis_validators_root)
    # genesis_validators_root = Digest.fromHex(
    #   "0x2170688a9e92595fb353c0a2ad6733431a8066c7ecb48ab3b2aaf9091a1722b1"
    # )
    forkDigests = newClone ForkDigests.init(metadata.cfg, genesis_validators_root)

  test "HistoricalSummaries Encoding/Decoding and Verification":
    const file = testVectorDir & "historical_summaries_with_proof.yaml"
    let
      testCase = YamlHistoricalSummariesWithProof.loadFromYaml(file).valueOr:
        raiseAssert "Invalid test vector file: " & error

      contentKeyEncoded = testCase.content_key.hexToSeqByte()
      contentValueEncoded = testCase.content_value.hexToSeqByte()

      # Decode content and content key
      contentKey = decodeSsz(contentKeyEncoded, ContentKey)
      contentValue =
        decodeSsz(forkDigests[], contentValueEncoded, HistoricalSummariesWithProof)
    check:
      contentKey.isOk()
      contentValue.isOk()

    let summariesWithProof = contentValue.value()
    let root = hash_tree_root(summariesWithProof.historical_summaries)

    check:
      root.data == testCase.historical_summaries_root.hexToSeqByte()
      summariesWithProof.epoch == testCase.epoch
      verifyProof(summariesWithProof, Digest.fromHex(testCase.beacon_state_root))

    # Encode content and content key
    let consensusFork = consensusForkAtEpoch(metadata.cfg, summariesWithProof.epoch)
    let forkDigest = atConsensusFork(forkDigests[], consensusFork)
    check:
      encodeSsz(summariesWithProof, forkDigest) == contentValueEncoded
      encode(contentKey.value()).asSeq() == contentKeyEncoded
