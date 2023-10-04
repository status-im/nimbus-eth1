#
# helper tool to dump debugging data for persisted block
# usage: dumper [--datadir:your_path] --head:blockNumber
#

import
  stint,
  ../nimbus/common/common,
  ../nimbus/db/core_db/persistent,
  ../nimbus/core/executor,
  ../nimbus/[vm_state, vm_types],
  ../nimbus/tracer,
  ./configuration # must be late (compilation annoyance)

proc dumpDebug(com: CommonRef, blockNumber: UInt256) =
  var
    capture = com.db.capture()
    captureCom = com.clone(capture.recorder)

  let transaction = capture.recorder.beginTransaction()
  defer: transaction.dispose()


  let
    parentNumber = blockNumber - 1
    parent = captureCom.db.getBlockHeader(parentNumber)
    header = captureCom.db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    body = captureCom.db.getBlockBody(headerHash)
    vmState = BaseVMState.new(parent, header, captureCom)

  discard captureCom.db.setHead(parent, true)
  discard vmState.processBlock(header, body)

  transaction.rollback()
  dumpDebuggingMetaData(captureCom, header, body, vmState, false)

proc main() {.used.} =
  let conf = getConfiguration()
  let com = CommonRef.new(newCoreDbRef(LegacyDbPersistent, conf.dataDir), false)

  if conf.head != 0.u256:
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
