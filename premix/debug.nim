import
  std/[json, os],
  stew/byteutils,
  chronicles,
  ../nimbus/[vm_state, vm_types],
  ../nimbus/core/executor,
  ./premixcore, ./prestate,
  ../nimbus/tracer,
  ../nimbus/common/common

proc prepareBlockEnv(node: JsonNode, memoryDB: CoreDbRef) =
  let state = node["state"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.kvt.put(key, value)

proc executeBlock(blockEnv: JsonNode, memoryDB: CoreDbRef, blockNumber: UInt256) =
  let
    parentNumber = blockNumber - 1
    com = CommonRef.new(memoryDB)
    parent = com.db.getBlockHeader(parentNumber)
    header = com.db.getBlockHeader(blockNumber)
    body   = com.db.getBlockBody(header.blockHash)

  let transaction = memoryDB.beginTransaction()
  defer: transaction.dispose()

  let
    vmState = BaseVMState.new(parent, header, com)
    validationResult = vmState.processBlockNotPoA(header, body)

  if validationResult != ValidationResult.OK:
    error "block validation error", validationResult
  else:
    info "block validation success", validationResult, blockNumber

  transaction.rollback()
  dumpDebuggingMetaData(com, header, body, vmState, false)
  let
    fileName = "debug" & $blockNumber & ".json"
    nimbus   = json.parseFile(fileName)
    geth     = blockEnv["geth"]

  processNimbusData(nimbus)

  # premix data goes to report page
  generatePremixData(nimbus, geth)

  # prestate data goes to debug tool and contains data
  # needed to execute single block
  generatePrestate(nimbus, geth, blockNumber, parent, header, body)

proc main() =
  if paramCount() == 0:
    echo "usage: debug blockxxx.json"
    quit(QuitFailure)

  let
    blockEnv = json.parseFile(paramStr(1))
    memoryDB = newCoreDbRef(LegacyDbMemory)
    blockNumber = UInt256.fromHex(blockEnv["blockNumber"].getStr())

  prepareBlockEnv(blockEnv, memoryDB)
  executeBlock(blockEnv, memoryDB, blockNumber)

main()
