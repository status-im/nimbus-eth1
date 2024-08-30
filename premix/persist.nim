# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# use this module to quickly populate db with data from geth/parity

import
  std/os,
  chronicles,
  ../nimbus/errors,
  ../nimbus/core/chain,
  ../nimbus/common,
  ../nimbus/db/opts,
  ../nimbus/db/[core_db/persistent, storage_types],
  configuration  # must be late (compilation annoyance)

when defined(graphql):
  import graphql_downloader
else:
  import downloader

# `lmdb` is not used, anymore
#
# const
#   manualCommit = nimbus_db_backend == "lmdb"
#
# template persistToDb(db: ChainDB, body: untyped) =
#   when manualCommit:
#     if not db.txBegin(): doAssert(false)
#   body
#   when manualCommit:
#     if not db.txCommit(): doAssert(false)

template persistToDb(db: CoreDbRef, body: untyped) =
  block: body

proc contains(kvt: CoreDbKvtRef; key: openArray[byte]): bool =
  kvt.hasKeyRc(key).expect "valid bool"

proc main() {.used.} =
  # 97 block with uncles
  # 46147 block with first transaction
  # 46400 block with transaction
  # 46402 block with first contract: failed
  # 47205 block with first success contract
  # 48712 block with 5 transactions
  # 48915 block with contract
  # 49018 first problematic block
  # 49439 first block with contract call
  # 52029 first block with receipts logs
  # 66407 failed transaction

  let conf = configuration.getConfiguration()
  let com = CommonRef.new(
    newCoreDbRef(DefaultDbPersistent, conf.dataDir, DbOptions.init()),
    conf.netId, networkParams(conf.netId))

  # move head to block number ...
  if conf.head != 0'u64:
    var parentBlock = requestBlock(conf.head, { DownloadAndValidate })
    discard com.db.setHead(parentBlock.header)

  let kvt = com.db.ctx.getKvt()
  var head = com.db.getCanonicalHead()
  var blockNumber = head.number + 1
  var chain = newChain(com)

  let numBlocksToCommit = conf.numCommits

  var blocks = newSeqOfCap[EthBlock](numBlocksToCommit)
  var one    = 1'u64

  var numBlocks = 0
  var counter = 0
  var retryCount = 0

  while true:
    var thisBlock: Block
    try:
      thisBlock = requestBlock(blockNumber, { DownloadAndValidate })
    except CatchableError as e:
      if retryCount < 3:
        warn "Unable to get block data via JSON-RPC API", error = e.msg
        inc retryCount
        sleep(1000)
        continue
      else:
        raise e

    blocks.add EthBlock.init(thisBlock.header, thisBlock.body)
    info "REQUEST HEADER", blockNumber=blockNumber, txs=thisBlock.body.transactions.len

    inc numBlocks
    blockNumber += one

    if numBlocks == numBlocksToCommit:
      persistToDb(com.db):
        let res = chain.persistBlocks(blocks)
        res.isOkOr:
          raise newException(ValidationError, "Error when validating blocks: " & res.error)
      numBlocks = 0
      blocks.setLen(0)

    inc counter
    if conf.maxBlocks != 0 and counter >= conf.maxBlocks:
      break

  if numBlocks > 0:
    persistToDb(com.db):
      let res = chain.persistBlocks(blocks)
      res.isOkOr:
        raise newException(ValidationError, "Error when validating blocks: " & res.error)

when isMainModule:
  var message: string

  ## Processing command line arguments
  if configuration.processArguments(message) != Success:
    if len(message) > 0:
      echo message
    echo "Usage: persist --datadir=<DATA_DIR> --maxblocks=<MAX_BLOCKS> --head=<HEAD> --numcommits=<NUM_COMMITS> --netid=<NETWORK_ID>"
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  try:
    main()
  except CatchableError:
    echo getCurrentExceptionMsg()
