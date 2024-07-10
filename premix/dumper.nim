# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

#
# helper tool to dump debugging data for persisted block
# usage: dumper [--datadir:your_path] --head:blockNumber
#

import
  results,
  ../nimbus/common/common,
  ../nimbus/db/opts,
  ../nimbus/db/core_db/persistent,
  ../nimbus/core/executor,
  ../nimbus/[evm/state, evm/types],
  ../nimbus/tracer,
  ./configuration # must be late (compilation annoyance)

proc dumpDebug(com: CommonRef, blockNumber: BlockNumber) =
  var
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)

  let transaction = capture.recorder.ctx.newTransaction()
  defer: transaction.dispose()


  var
    parentNumber = blockNumber - 1
    parent = captureCom.db.getBlockHeader(parentNumber)
    blk = captureCom.db.getEthBlock(blockNumber)
    vmState = BaseVMState.new(parent, blk.header, captureCom)

  discard captureCom.db.setHead(parent, true)
  discard vmState.processBlock(blk)

  transaction.rollback()
  vmState.dumpDebuggingMetaData(blk, false)

proc main() {.used.} =
  let conf = getConfiguration()
  let com = CommonRef.new(
    newCoreDbRef(DefaultDbPersistent, conf.dataDir, DbOptions.init()))

  if conf.head != 0'u64:
    dumpDebug(com, conf.head)

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
