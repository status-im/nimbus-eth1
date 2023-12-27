# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This is a fake bridge that reads state from a directory and backfills it to the portal state network.

{.push raises: [].}

import
  std/[os, sugar],
  confutils, confutils/std/net, chronicles, chronicles/topics_registry,
  json_rpc/clients/httpclient,
  chronos,
  stew/[byteutils, io2],
  eth/async_utils,
  eth/common/eth_types,
  ../../network/state/state_content,
  ../../rpc/portal_rpc_client,
  ../../logging,
  ../eth_data_exporter/cl_data_exporter,
  ./state_bridge_conf

type JsonAccount* = object
  nonce*: int
  balance*: string
  storage_hash*: string
  code_hash*: string

type JsonProof* = object
  address*: string
  state*: JsonAccount
  proof*: seq[string]

type JsonProofVector* = object
  `block`*: int
  block_hash*: string
  state_root*: string
  proofs*: seq[JsonProof]

proc run(config: StateBridgeConf) {.raises: [CatchableError].} =
  setupLogging(config.logLevel, config.logStdout)

  notice "Launching Fluffy fake state bridge",
    cmdParams = commandLineParams()

  let portalRpcClient = newRpcHttpClient()

  proc backfill(rpcAddress: string, rpcPort: Port) {.async raises: [OSError].} =
    echo "Backfilling...", config.rpcAddress, ":", config.rpcPort
    await portalRpcClient.connect(config.rpcAddress, Port(config.rpcPort), false)
    let files = collect(for f in walkDir(config.dataDir): f.path)
    for file in files:
      let
        content = readAllFile(file).valueOr:
          echo "Skipping file ", file, " because of error \n", error
          continue
        decoded =
          try:
            Json.decode(content, state_bridge.JsonProofVector)
          except SerializationError as e:
            echo "Skipping file ", file, " because of error \n", e.msg
            continue
        state_root = hexToByteArray[sizeof(Bytes32)](decoded.state_root)

      for proof in decoded.proofs:
        let
          address = hexToByteArray[sizeof(state_content.Address)](proof.address)
          key = AccountTrieProofKey(
            address: address,
            stateRoot: state_root)
          contentKey = ContentKey(
            contentType: ContentType.accountTrieProof,
            accountTrieProofKey: key)
          encodedKey = encode(contentKey)

        var accountTrieProof = AccountTrieProof(@[])
        for witness in proof.proof:
          let witnessNode = ByteList(hexToSeqByte(witness))
          discard accountTrieProof.add(witnessNode)
        discard await portalRpcClient.portal_stateGossip(encodedKey.asSeq().toHex(), SSZ.encode(accountTrieProof).toHex())
    await portalRpcClient.close()
    notice "Backfill done..."

  waitFor backfill(config.rpcAddress, Port(config.rpcPort))

  while true:
    poll()

when isMainModule:
  {.pop.}
  let config = StateBridgeConf.load()
  {.push raises: [].}

  case config.cmd
  of StateBridgeCmd.noCommand:
    run(config)
