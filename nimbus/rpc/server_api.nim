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
  ./rpc_types

{.push raises: [].}

type
  ServerAPIRef = ref object
    com: CommonRef
    chain: ForkedChainRef

const
  defaultTag = blockId("latest")

func newServerAPI*(c: ForkedChainRef): ServerAPIRef =
  new(result)
  result.com = c.com
  result.chain = c

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
