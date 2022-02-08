# Nimbus - Steps towards a fast and small Ethereum data store
#
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  options, memfiles,
  stint, chronicles, stew/byteutils,
  eth/common/eth_types,
  ".."/[db/db_chain, db/accounts_cache, vm_state, p2p/executor/process_block],
  "."/[host_types, db_compare]

template toHex(hash: Hash256): string = hash.data.toHex

proc dbCompareExecBlock*(chainDB: BaseChainDB, blockNumber: BlockNumber): bool =
  debug "DB COMPARE: Trying to execute block", `block`=blockNumber
  try:

    var blockHash: Hash256
    if not chainDB.getBlockHash(blockNumber, blockHash):
      error "*** DB COMPARE: Don't have block hash for block",
        `block`=blockNumber
      return false

    var header: BlockHeader
    if not chainDB.getBlockHeader(blockHash, header):
      error "*** DB COMPARE: Don't have block header for block",
        `block`=blockNumber
      return false

    var body: BlockBody
    if not chainDB.getBlockBody(blockHash, body):
      error "*** DB COMPARE: Don't have block body for block",
        `block`=blockNumber
      return false

    if blockNumber == 0:
      debug "*** DB COMPARE: No calculations to be done for genesis block"
      return true

    var parentHeader: BlockHeader
    if not chainDB.getBlockHeader(header.parentHash, parentHeader):
      error "*** DB COMPARE: Don't have block header for parent block",
        `block`=blockNumber, parentBlock=(blockNumber-1)
      return false

    debug "DB COMPARE: Read block from local db ok",
      `block`=blockNumber, blockHash=blockHash.toHex,
      stateRoot=header.stateRoot.toHex

    dbCompareErrorCount = 0

    let stateDb = AccountsCache.init(chainDB.db, parentHeader.stateRoot)
    let vmState = newBaseVMState(stateDB, header, chainDB)
    let validationResult = vmState.processBlock(nil, header, body)
    if validationResult != OK:
      error "*** DB COMPARE: Block validation failed, not even affected by new DB",
        `block`=blockNumber, blockHash=blockHash.toHex

    if dbCompareErrorCount == 0:
      debug "DB COMPARE: Block execution completed ok",
        `block`=blockNumber, blockHash=blockHash.toHex
    else:
      error "***DB ERRORS: Block execution has comparison errors",
        errorCount=dbCompareErrorCount,
        `block`=blockNumber, blockHash=blockHash.toHex
    result = validationResult == OK

  except Exception as e:
    error "*** DB COMPARE: Exception while trying to execute block",
      `block`=blockNumber, error=e.msg

proc dbCompareExecBlocks*(chainDB: BaseChainDB,
                          blockNumberStart, blockNumberEnd: Option[uint64]) =
  var blockNumber = blockNumberStart.get(0.uint64).toBlockNumber
  var stopAt = blockNumberEnd.get(high(int64).uint64).toBlockNumber

  while true:
    if not dbCompareExecBlock(chainDB, blockNumber):
      error "*** DB COMPARE: Stopping block execution due to errors at block",
        `block`=blockNumber
      break
    if blockNumber >= stopAt:
      break
    blockNumber = blockNumber + 1
