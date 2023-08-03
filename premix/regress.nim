import
  chronicles,
  ../nimbus/[vm_state, vm_types],
  ../nimbus/core/executor,
  ../nimbus/common/common,
  ../nimbus/db/core_db/persistent,
  configuration # must be late (compilation annoyance)

const
  numBlocks = 256

proc validateBlock(com: CommonRef, blockNumber: BlockNumber): BlockNumber =
  var
    parentNumber = blockNumber - 1
    parent = com.db.getBlockHeader(parentNumber)
    headers = newSeq[BlockHeader](numBlocks)
    bodies  = newSeq[BlockBody](numBlocks)
    lastBlockHash: Hash256

  for i in 0 ..< numBlocks:
    headers[i] = com.db.getBlockHeader(blockNumber + i.u256)
    bodies[i]  = com.db.getBlockBody(headers[i].blockHash)

  let transaction = com.db.beginTransaction()
  defer: transaction.dispose()

  for i in 0 ..< numBlocks:
    stdout.write blockNumber + i.u256
    stdout.write "\r"

    let
      vmState = BaseVMState.new(parent, headers[i], com)
      validationResult = vmState.processBlockNotPoA(headers[i], bodies[i])

    if validationResult != ValidationResult.OK:
      error "block validation error", validationResult, blockNumber = blockNumber + i.u256

    parent = headers[i]

  transaction.rollback()
  result = blockNumber + numBlocks.u256

proc main() {.used.} =
  let
    conf = getConfiguration()
    com = CommonRef.new(newCoreDbRef(LegacyDbPersistent, conf.dataDir), false)

  # move head to block number ...
  if conf.head == 0.u256:
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
