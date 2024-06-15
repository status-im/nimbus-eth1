# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  chronicles,
  ../nimbus/[evm/state, evm/types],
  ../nimbus/core/executor,
  ../nimbus/common/common,
  ../nimbus/db/opts,
  ../nimbus/db/core_db/persistent,
  configuration # must be late (compilation annoyance)

const
  numBlocks = 256

proc validateBlock(com: CommonRef, blockNumber: BlockNumber): BlockNumber =
  var
    parentNumber = blockNumber - 1
    parent = com.db.getBlockHeader(parentNumber)
    blocks = newSeq[EthBlock](numBlocks)

  for i in 0 ..< numBlocks:
    blocks[i] = com.db.getEthBlock(blockNumber + i.BlockNumber)

  let transaction = com.db.newTransaction()
  defer: transaction.dispose()

  for i in 0 ..< numBlocks:
    stdout.write blockNumber + i.BlockNumber
    stdout.write "\r"

    let
      vmState = BaseVMState.new(parent, blocks[i].header, com)
      validationResult = vmState.processBlock(blocks[i])

    if validationResult.isErr:
      error "block validation error",
        err = validationResult.error(), blockNumber = blockNumber + i.BlockNumber

    parent = blocks[i].header

  transaction.rollback()
  result = blockNumber + numBlocks.BlockNumber

proc main() {.used.} =
  let
    conf = getConfiguration()
    com = CommonRef.new(newCoreDbRef(
      DefaultDbPersistent, conf.dataDir, DbOptions.init()))

  # move head to block number ...
  if conf.head == 0'u64:
    raise newException(ValueError, "please set block number with --head: blockNumber")

  var counter = 0
  var blockNumber = conf.head

  while true:
    blockNumber = com.validateBlock(blockNumber)

    inc counter
    if conf.maxBlocks != 0 and counter >= conf.maxBlocks:
      break

when isMainModule:
  var message: string

  ## Processing command line arguments
  if processArguments(message) != Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  try:
    main()
  except:
    echo getCurrentExceptionMsg()
