# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Portal bridge to inject beacon chain content into the network
# The bridge act as a middle man between a consensus full node, through the,
# Eth Beacon Node API REST-API), and a Portal node, through the Portal
# JSON-RPC API.
#
# Portal Network <-> Portal Client (e.g. fluffy) <--JSON-RPC--> bridge <--REST--> consensus client (e.g. Nimbus-eth2)
#
# The Consensus client must support serving the Beacon LC data.
#
# Bootstraps and updates can be backfilled, however how to do this for multiple
# bootstraps is still unsolved.
#
# Updates, optimistic updates and finality updates are injected as they become
# available.
#

{.push raises: [].}

import
  std/[os, sugar],
  confutils, confutils/std/net, chronicles, chronicles/topics_registry,
  json_rpc/clients/httpclient,
  chronos,
  stew/byteutils,
  eth/async_utils,
  ../../network/state/state_content,
  ../../rpc/portal_rpc_client,
  ../../logging,
  ../eth_data_exporter/cl_data_exporter,
  ./state_bridge_conf

const restRequestsTimeout = 30.seconds

# TODO: From nimbus_binary_common, but we don't want to import that.
proc sleepAsync(t: TimeDiff): Future[void] =
  sleepAsync(nanoseconds(
    if t.nanoseconds < 0: 0'i64 else: t.nanoseconds))

proc run(config: BeaconBridgeConf) {.raises: [CatchableError].} =
  setupLogging(config.logLevel, config.logStdout)

  notice "Launching Fluffy fake state bridge",
    cmdParams = commandLineParams()

  let portalRpcClient = newRpcHttpClient()

  proc backfill(rpcAddress: string, rpcPort: Port) {.async raises: [OSError].} =
    echo "Backfilling...", config.rpcAddress, ":", config.rpcPort
    await portalRpcClient.connect(config.rpcAddress, Port(config.rpcPort), false)
    let files = collect(for f in walkDir(config.dataDir): f.path)
    for file in files:
      try:
        let content = io.readFile(file).parseJson()
        let state_root = hexToByteArray[sizeof(Bytes32)](content["state_root"].getStr())
        for proof in content["proofs"]:
          let address = hexToByteArray[sizeof(state_content.Address)](proof["address"].getStr())
          let key = AccountTrieProofKey(
            address: address,
            stateRoot: state_root)
          let contentKey = ContentKey(
            contentType: ContentType.accountTrieProof,
            accountTrieProofKey: key)
          let encodedKey = encode(contentKey)

          var accountTrieProof = AccountTrieProof(@[])
          for witness in proof["proof"]:
            let witnessNode = ByteList(hexToSeqByte(witness.getStr()))
            discard accountTrieProof.add(witnessNode)
          let state = proof["state"]
          let accountState = AccountState(
            nonce: state["nonce"].getInt().uint64(),
            balance: UInt256.fromHex(state["balance"].getStr()),
            storageHash: MDigest[256].fromHex(state["storage_hash"].getStr()),
            codeHash: MDigest[256].fromHex(state["code_hash"].getStr()),
            stateRoot: MDigest[256].fromHex(content["state_root"].getStr()),
            proof: accountTrieProof)
          let encodedValue = SSZ.encode(accountState)
          discard await portalRpcClient.portal_stateGossip(encodedKey.asSeq().toHex(), encodedValue.toHex())
      except Exception as e:
        echo "Skipping file ", file, " because of error \n", e.msg
        continue
    await portalRpcClient.close()
    notice "Backfill done..."

  waitFor backfill(config.rpcAddress, Port(config.rpcPort))

  while true:
    poll()

when isMainModule:
  {.pop.}
  let config = BeaconBridgeConf.load()
  {.push raises: [].}

  case config.cmd
  of BeaconBridgeCmd.noCommand:
    run(config)
