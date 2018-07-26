# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
import strutils, nimcrypto, eth_common, stint, eth_trie/[memdb, types]
import
  json_rpc/server, ../vm_state, ../logging, ../db/[db_chain, state_db],
  ../constants, ../config

proc setupCommonRPC*(server: RpcServer) =
  server.rpc("web3_clientVersion") do() -> string:
    result = NimbusIdent

  server.rpc("web3_sha3") do(data: string) -> string:
    var rawdata = nimcrypto.fromHex(data)
    result = "0x" & $keccak_256.digest(rawdata)
  
  server.rpc("eth_getBalance") do(address: array[20, byte], quantityTag: string) -> int:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## quantityTag: integer block number, or the string "latest", "earliest" or "pending", see the default block parameter.
    ## Returns integer of the current balance in wei.
    var blockNum: BlockNumber
    let qt = quantityTag.toLowerAscii
    case quantityTag
    of "latest": discard  # TODO: Get latest block
    of "earliest": blockNum = GENESIS_BLOCK_NUMBER
    of "pending": discard # TODO
    else:
      # Note: `fromHex` can raise ValueError on bad data.
      blockNum = stint.fromHex(UInt256, quantityTag)

    let header = BlockHeader(blockNumber: blockNum)
    var
      memDb = newMemDB()
      vmState = newBaseVMState(header, newBaseChainDB(trieDB memDb))
    let
      account_db = vmState.readOnlyStateDb
      balance = account_db.get_balance(address)

    return balance.toInt
  
