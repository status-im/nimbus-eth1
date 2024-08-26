# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  stint,
  web3/conversions,
  json_rpc/rpcserver,
  ../common,
  ../db/ledger,
  ../core/chain/forked_chain,
  ../beacon/web3_eth_conv,
  ./rpc_types,
  ./server_api_helpers

type
  ServerAPIRef = ref object
    com: CommonRef
    chain: ForkedChainRef

const
  defaultTag = blockId("latest")

func newServerAPI*(c: ForkedChainRef): ServerAPIRef =
  ServerAPIRef(
    com: c.com,
    chain: c,
  )

proc headerFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[common.BlockHeader, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest": return ok(api.chain.latestHeader)
    else:
      return err("Unsupported block tag " & tag)
  else:
    let blockNum = common.BlockNumber blockTag.number
    return api.chain.headerByNumber(blockNum)

proc ledgerFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[LedgerRef, string] =
  let header = ?api.headerFromTag(blockTag)
  if api.chain.stateReady(header):
    ok(LedgerRef.init(api.com.db, header.stateRoot))
  else:
    # TODO: Replay state?
    err("Block state not ready")

proc blockFromTag(api: ServerAPIRef, blockTag: BlockTag): Result[EthBlock, string] =
  if blockTag.kind == bidAlias:
    let tag = blockTag.alias.toLowerAscii
    case tag
    of "latest": return ok(api.chain.latestBlock)
    else:
      return err("Unsupported block tag " & tag)
  else:
    let blockNum = common.BlockNumber blockTag.number
    return api.chain.blockByNumber(blockNum)

proc setupServerAPI*(api: ServerAPIRef, server: RpcServer) =

  server.rpc("eth_getBalance") do(data: Web3Address, blockTag: BlockTag) -> UInt256:
    ## Returns the balance of the account of given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = ethAddr data
    result = ledger.getBalance(address)

  server.rpc("eth_getStorageAt") do(data: Web3Address, slot: UInt256, blockTag: BlockTag) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = ethAddr data
      value   = ledger.getStorage(address, slot)
    result = w3FixedBytes value

  server.rpc("eth_getTransactionCount") do(data: Web3Address, blockTag: BlockTag) -> Web3Quantity:
    ## Returns the number of transactions ak.s. nonce sent from an address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = ethAddr data
      nonce   = ledger.getNonce(address)
    result = w3Qty nonce

  server.rpc("eth_blockNumber") do() -> Web3Quantity:
    ## Returns integer of the current block number the client is on.
    result = w3Qty(api.chain.latestNumber)

  server.rpc("eth_chainId") do() -> Web3Quantity:
    return w3Qty(distinctBase(api.com.chainId))

  server.rpc("eth_getCode") do(data: Web3Address, blockTag: BlockTag) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## blockTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns the code from the given address.
    let
      ledger  = api.ledgerFromTag(blockTag).valueOr:
        raise newException(ValueError, error)
      address = ethAddr data
    result = ledger.getCode(address).bytes()

  server.rpc("eth_getBlockByHash") do(data: Web3Hash, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by hash.
    ##
    ## data: Hash of a block.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let blockHash = data.ethHash

    let blk = api.chain.blockByHash(blockHash).valueOr:
      return nil

    return populateBlockObject(blockHash, blk, fullTransactions)

  server.rpc("eth_getBlockByNumber") do(blockTag: BlockTag, fullTransactions: bool) -> BlockObject:
    ## Returns information about a block by block number.
    ##
    ## blockTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## fullTransactions: If true it returns the full transaction objects, if false only the hashes of the transactions.
    ## Returns BlockObject or nil when no block was found.
    let blk = api.blockFromTag(blockTag).valueOr:
      return nil

    let blockHash = blk.header.blockHash
    return populateBlockObject(blockHash, blk, fullTransactions)

  server.rpc("eth_syncing") do() -> SyncingStatus:
    ## Returns SyncObject or false when not syncing.
    if api.com.syncState != Waiting:
      let sync = SyncObject(
        startingBlock: w3Qty api.com.syncStart,
        currentBlock : w3Qty api.com.syncCurrent,
        highestBlock : w3Qty api.com.syncHighest
      )
      return SyncingStatus(syncing: true, syncObject: sync)
    else:
      return SyncingStatus(syncing: false)

