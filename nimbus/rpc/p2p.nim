# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
import
  nimcrypto, json_rpc/server, eth_p2p, hexstrings, strutils, stint,
  ../config, ../vm_state, ../constants, eth_trie/[memdb, types],
  ../db/[db_chain, state_db], eth_common

func headerFromTag(chain:BaseChainDB, blockTag: string): BlockHeader =
  let tag = blockTag.toLowerAscii
  case tag
  of "latest": result = chain.getCanonicalHead()
  of "earliest": result = chain.getCanonicalBlockHeaderByNumber(GENESIS_BLOCK_NUMBER)
  of "pending":
    #TODO: Implement get pending block
    raise newException(ValueError, "Pending tag not yet implemented")
  else:
    # Raises are trapped and wrapped in JSON when returned to the user.
    tag.validateHexQuantity
    let blockNum = stint.fromHex(UInt256, tag)
    result = chain.getCanonicalBlockHeaderByNumber(blockNum)

proc setupP2PRPC*(server: EthereumNode, rpcsrv: RpcServer) =
  rpcsrv.rpc("net_version") do() -> uint:
    let conf = getConfiguration()
    result = conf.net.networkId

  rpcsrv.rpc("eth_getBalance") do(address: array[20, byte], quantityTag: string) -> int:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.
    template chain: untyped = BaseChainDB(server.chain) # TODO: Sensible casting
    let
      header = chain.headerFromTag(quantityTag)
      vmState = newBaseVMState(header, chain)
      account_db = vmState.readOnlyStateDb
      balance = account_db.get_balance(address)

    return balance.toInt
  
