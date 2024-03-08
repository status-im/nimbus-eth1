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
  std/[json, tables, hashes],
  eth/trie/trie_defs,
  stint, stew/byteutils, chronicles,
  ../nimbus/[vm_state, vm_types],
  ../nimbus/utils/utils,
  ../nimbus/tracer,
  ../nimbus/db/[core_db, state_db/read_write],
  ../nimbus/core/executor,
  ../nimbus/common/common,
  "."/[configuration, downloader, parser, premixcore]

const
  emptyCodeHash = blankStringHash

proc store(memoryDB: CoreDbRef, branch: JsonNode) =
  for p in branch:
    let rlp = hexToSeqByte(p.getStr)
    let hash = keccakHash(rlp)
    memoryDB.defaultKvt.put(hash.data, rlp)

proc parseAddress(address: string): EthAddress =
  hexToByteArray(address, result)

proc parseU256(val: string): UInt256 =
  UInt256.fromHex(val)

proc prepareBlockEnv(parent: BlockHeader, thisBlock: Block): CoreDbRef =
  var
    accounts     = requestPostState(thisBlock)
    memoryDB     = newCoreDbRef LegacyDbMemory
    accountDB    = newAccountStateDB(memoryDB, parent.stateRoot, false)
    parentNumber = %(parent.blockNumber.prefixHex)

  for address, account in accounts:
    updateAccount(address, account, parent.blockNumber)
    let
      accountProof = account["accountProof"]
      storageProof = account["storageProof"]
      address      = parseAddress(address)
      acc          = parseAccount(account)

    memoryDB.store(accountProof)
    accountDB.setAccount(address, acc)

    for storage in storageProof:
      let
        key = parseU256(storage["key"].getStr)
        val = parseU256(storage["value"].getStr)
        proof = storage["proof"]
      memoryDB.store(proof)
      accountDB.setStorage(address, key, val)

    if acc.codeHash != emptyCodeHash:
      let codeStr = request("eth_getCode", %[%address.prefixHex, parentNumber])
      let code = hexToSeqByte(codeStr.getStr)
      accountDB.setCode(address, code)

    accountDB.setAccount(address, acc)

  result = memoryDB

type
  HunterVMState = ref object of BaseVMState
    headers: Table[BlockNumber, BlockHeader]

proc hash*(x: UInt256): Hash =
  result = hash(x.toBytesBE)

proc new(T: type HunterVMState; parent, header: BlockHeader, com: CommonRef): T =
  new result
  result.init(parent, header, com)
  result.headers = initTable[BlockNumber, BlockHeader]()

method getAncestorHash*(vmState: HunterVMState, blockNumber: BlockNumber): Hash256 {.gcsafe.} =
  if blockNumber in vmState.headers:
    result = vmState.headers[blockNumber].hash
  else:
    let data = requestHeader(blockNumber)
    let header = parseBlockHeader(data)
    result = header.hash
    vmState.headers[blockNumber] = header

proc putAncestorsIntoDB(vmState: HunterVMState, db: CoreDbRef) =
  for header in vmState.headers.values:
    db.addBlockNumberToHashLookup(header)

proc huntProblematicBlock(blockNumber: UInt256): ValidationResult =
  let
    # prepare needed state from previous block
    parentNumber = blockNumber - 1
    thisBlock    = requestBlock(blockNumber)
    parentBlock  = requestBlock(parentNumber)
    memoryDB     = prepareBlockEnv(parentBlock.header, thisBlock)

    # try to execute current block
    com = CommonRef.new(memoryDB, false)

  discard com.db.setHead(parentBlock.header, true)

  let transaction = memoryDB.beginTransaction()
  defer: transaction.dispose()
  let
    vmState = HunterVMState.new(parentBlock.header, thisBlock.header, com)
    validationResult = vmState.processBlock(thisBlock.header, thisBlock.body)

  if validationResult != ValidationResult.OK:
    transaction.rollback()
    putAncestorsIntoDB(vmState, com.db)
    dumpDebuggingMetaData(com, thisBlock.header, thisBlock.body, vmState, false)

  result = validationResult

proc main() {.used.} =
  let conf = getConfiguration()

  if conf.head == 0.u256:
    echo "please specify the starting block with `--head:blockNumber`"
    quit(QuitFailure)

  if conf.maxBlocks == 0:
    echo "please specify the number of problematic blocks you want to hunt with `--maxBlocks:number`"
    quit(QuitFailure)

  var
    problematicBlocks = newSeq[UInt256]()
    blockNumber = conf.head

  while true:
    echo blockNumber
    if huntProblematicBlock(blockNumber) != ValidationResult.OK:
      echo "shot down problematic block: ", blockNumber
      problematicBlocks.add blockNumber
    blockNumber = blockNumber + 1
    if problematicBlocks.len >= conf.maxBlocks:
      echo "Problematic blocks: ", problematicBlocks
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
