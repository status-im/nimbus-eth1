# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Tool to verify that certain Portal content is available on the network.
# Currently only supports checking `EpochAccumulator`s of the history network.

{.push raises: [].}

import
  confutils,
  chronicles,
  chronicles/topics_registry,
  stew/byteutils,
  ../network_metadata,
  ../network/history/[accumulator, history_content, history_network],
  ../rpc/portal_rpc_client

type ContentVerifierConf* = object
  logLevel* {.
    defaultValue: LogLevel.INFO,
    defaultValueDesc: $LogLevel.INFO,
    desc: "Sets the log level",
    name: "log-level"
  .}: LogLevel

  rpcAddress* {.
    desc: "Address of the JSON-RPC service",
    defaultValue: "127.0.0.1",
    name: "rpc-address"
  .}: string

  rpcPort* {.
    defaultValue: 8545, desc: "Port of the JSON-RPC service", name: "rpc-port"
  .}: uint16

proc checkAccumulators(client: RpcClient) {.async.} =
  let accumulator =
    # Get it from binary file containing SSZ encoded accumulator
    try:
      SSZ.decode(finishedAccumulator, FinishedAccumulator)
    except SszError as err:
      raiseAssert "Invalid baked-in accumulator: " & err.msg

  for i, hash in accumulator.historicalEpochs:
    let root = Digest(data: hash)
    let contentKey = ContentKey.init(epochAccumulator, root)

    try:
      let content = await client.portal_historyRecursiveFindContent(
        contentKey.encode.asSeq().toHex()
      )

      let res = decodeSsz(hexToSeqByte(content), EpochAccumulator)
      if res.isErr():
        echo "[Invalid] EpochAccumulator number " & $i & ": " & $root & " error: " &
          res.error
      else:
        let epochAccumulator = res.get()
        let resultingRoot = hash_tree_root(epochAccumulator)
        if resultingRoot == root:
          echo "[Available] EpochAccumulator number " & $i & ": " & $root
        else:
          echo "[Invalid] EpochAccumulator number " & $i & ": " & $root &
            " error: Invalid root"
    except RpcPostError as e:
      # RpcPostError when for example timing out on the request. Could retry
      # in this case.
      fatal "Error occured on JSON-RPC request", error = e.msg
      quit 1
    except ValueError as e:
      # Either an error with the provided content key or the content was
      # simply not available in the network
      echo "[Not Available] EpochAccumulator number " & $i & ": " & $root & " error: " &
        e.msg

    # Using the http connection re-use seems to slow down these sequentual
    # requests considerably. Force a new connection setup by doing a close after
    # each request.
    await client.close()

proc run(config: ContentVerifierConf) {.async.} =
  let client = newRpcHttpClient()
  await client.connect(config.rpcAddress, Port(config.rpcPort), false)

  await checkAccumulators(client)

when isMainModule:
  {.pop.}
  let config = ContentVerifierConf.load()
  {.push raises: [].}

  setLogLevel(config.logLevel)

  waitFor run(config)
