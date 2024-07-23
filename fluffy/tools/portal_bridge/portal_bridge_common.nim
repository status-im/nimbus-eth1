# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  json_serialization,
  json_rpc/rpcclient,
  web3/[eth_api, eth_api_types],
  ../../rpc/rpc_calls/rpc_trace_calls,
  ./portal_bridge_conf

export rpcclient

proc newRpcClientConnect*(url: JsonRpcUrl): RpcClient =
  ## Instantiate a new JSON-RPC client and try to connect. Will quit on failure.
  case url.kind
  of HttpUrl:
    let client = newRpcHttpClient()
    try:
      waitFor client.connect(url.value)
    except CatchableError as e:
      fatal "Failed to connect to JSON-RPC server", error = $e.msg, url = url.value
      quit QuitFailure
    client
  of WsUrl:
    let client = newRpcWebSocketClient()
    try:
      waitFor client.connect(url.value)
    except CatchableError as e:
      fatal "Failed to connect to JSON-RPC server", error = $e.msg, url = url.value
      quit QuitFailure
    client

proc getBlockByNumber*(
    client: RpcClient, blockId: BlockIdentifier, fullTransactions: bool = true
): Future[Result[BlockObject, string]] {.async: (raises: []).} =
  let blck =
    try:
      let res = await client.eth_getBlockByNumber(blockId, fullTransactions)
      if res.isNil:
        return err("EL failed to provide requested block")

      res
    except CatchableError as e:
      return err("EL JSON-RPC eth_getBlockByNumber failed: " & e.msg)

  return ok(blck)

# type BlockObjectLite* = ref object
#   number*: BlockNumber # the block number. null when its pending block.
#   hash*: Hash256 # hash of the block. null when its pending block.
#   #parentHash*: Hash256                        # hash of the parent block.
#   #sha3Uncles*: Hash256                        # SHA3 of the uncles data in the block.
#   #logsBloom*: FixedBytes[256]                 # the bloom filter for the logs of the block. null when its pending block.
#   #transactionsRoot*: Hash256                  # the root of the transaction trie of the block.
#   stateRoot*: Hash256 # the root of the final state trie of the block.
#   #receiptsRoot*: Hash256                      # the root of the receipts trie of the block.
#   miner*: Address # the address of the beneficiary to whom the mining rewards were given.
#   #difficulty*: UInt256                        # integer of the difficulty for this block.
#   #extraData*: HistoricExtraData               # the "extra data" field of this block.
#   #gasLimit*: Quantity                         # the maximum gas allowed in this block.
#   #gasUsed*: Quantity                          # the total used gas by all transactions in this block.
#   #timestamp*: Quantity                        # the unix timestamp for when the block was collated.
#   #nonce*: Opt[FixedBytes[8]]               # hash of the generated proof-of-work. null when its pending block.
#   #mixHash*: Hash256
#   #size*: Quantity                             # integer the size of this block in bytes.
#   #totalDifficulty*: UInt256                   # integer of the total difficulty of the chain until this block.
#   #transactions*: seq[TxOrHash]                # list of transaction objects, or 32 Bytes transaction hashes depending on the last given parameter.
#   uncles*: seq[Hash256] # list of uncle hashes.
#   #baseFeePerGas*: Opt[UInt256]             # EIP-1559
#   #withdrawals*: Opt[seq[WithdrawalObject]] # EIP-4895
#   #withdrawalsRoot*: Opt[Hash256]           # EIP-4895
#   #blobGasUsed*: Opt[Quantity]              # EIP-4844
#   #excessBlobGas*: Opt[Quantity]            # EIP-4844
#   #parentBeaconBlockRoot*: Opt[Hash256]     # EIP-4788

# createJsonFlavor JsonC,
#   # automaticObjectSerialization = false,
#   # requireAllFields = false,
#   allowUnknownFields = true

# BlockObjectLite.useDefaultSerializationIn JsonC

proc getBlocksByNumber*(
    client: RpcClient, startBlock: uint64, batchSize: int
): Future[Result[seq[BlockObject], string]] {.async: (raises: []).} =
  let blck =
    try:
      let batch = client.prepareBatch()

      for i in 0 ..< batchSize:
        batch.eth_getBlockByNumber(blockId(startBlock + uint64(i)), false)

      let res = (await batch.send()).get()

      var blockObjs = newSeqOfCap[BlockObject](batchSize)
      for i in 0 ..< batchSize:
        blockObjs.add(Json.decode(res[i].result.string, BlockObject))

      blockObjs
    except CatchableError as e:
      return err("EL JSON-RPC eth_getBlockByNumber failed: " & e.msg)

  return ok(blck)

proc getUncleByBlockNumberAndIndex*(
    client: RpcClient, blockId: BlockIdentifier, index: Quantity
): Future[Result[BlockObject, string]] {.async: (raises: []).} =
  let blck =
    try:
      let res = await client.eth_getUncleByBlockNumberAndIndex(blockId, index)
      if res.isNil:
        return err("EL failed to provide requested uncle block")

      res
    except CatchableError as e:
      return err("EL JSON-RPC eth_getUncleByBlockNumberAndIndex failed: " & e.msg)

  return ok(blck)
