# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, os],
  asynctest,
  json_rpc/[rpcclient, rpcserver],
  stew/byteutils,
  ../nimbus/core/chain,
  ../nimbus/common/common,
  ../nimbus/rpc,
  ../nimbus/db/[ledger, core_db],
  ./rpc/experimental_rpc_client

type Hash256 = eth_types.Hash256

func ethAddr*(x: Address): EthAddress =
  EthAddress x

template toHash256(hash: untyped): Hash256 =
  fromHex(Hash256, hash.toHex())

proc importBlockData(
    node: JsonNode
): (CommonRef, Hash256, Hash256, UInt256) {.raises: [Exception].} =
  var
    blockNumber = UInt256.fromHex(node["blockNumber"].getStr())
    memoryDB = newCoreDbRef DefaultDbMemory
    config = chainConfigForNetwork(MainNet)
    com = CommonRef.new(memoryDB, config)
    state = node["state"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.kvt.put(key, value)

  let
    parentNumber = blockNumber - 1
    parent = com.db.getBlockHeader(parentNumber)
    blk = com.db.getEthBlock(blockNumber)
    chain = newChain(com)

  # it's ok if setHead fails here because of missing ancestors
  discard com.db.setHead(parent, true)
  let validationResult = chain.persistBlocks([blk])
  doAssert validationResult.isOk()

  return (com, parent.stateRoot, blk.header.stateRoot, blockNumber)

proc checkAndValidateProofs(
    db: CoreDbRef,
    parentStateRoot: KeccakHash,
    expectedStateRoot: KeccakHash,
    proofs: seq[ProofResponse],
) =
  let stateDB = LedgerRef.init(db, parentStateRoot)

  check:
    proofs.len() > 0

  for proof in proofs:
    let
      address = proof.address.ethAddr()
      balance = proof.balance
      nonce = proof.nonce.uint64
      codeHash = proof.codeHash.toHash256()
      storageHash = proof.storageHash.toHash256()
      slotProofs = proof.storageProof

      # TODO: Fix this test. Update the code by checking if codeHash has changed
      # and calling eth_getCode to set the updated code in the stateDB
      # if code.len() > 0:
      #   stateDB.setCode(address, code)

    stateDB.setBalance(address, balance)
    stateDB.setNonce(address, nonce)

    for slotProof in slotProofs:
      stateDB.setStorage(address, slotProof.key, slotProof.value)

    # the account doesn't exist due to a self destruct
    if codeHash == ZERO_HASH256 and storageHash == ZERO_HASH256:
      stateDB.deleteAccount(address)

    stateDB.persist()

    check stateDB.getBalance(address) == balance
    check stateDB.getNonce(address) == nonce

    if codeHash == ZERO_HASH256 or codeHash == EMPTY_CODE_HASH:
      check stateDB.getCode(address).len() == 0
      check stateDB.getCodeHash(address) == EMPTY_CODE_HASH
    else:
      check stateDB.getCodeHash(address) == codeHash

    if storageHash == ZERO_HASH256 or storageHash == EMPTY_ROOT_HASH:
      check stateDB.getStorageRoot(address) == EMPTY_ROOT_HASH
    else:
      check stateDB.getStorageRoot(address) == storageHash

  check stateDB.rootHash == expectedStateRoot

proc importBlockDataFromFile(
    file: string
): (CommonRef, Hash256, Hash256, UInt256) {.raises: [].} =
  try:
    let fileJson = json.parseFile("tests" / "fixtures" / "PersistBlockTests" / file)
    return importBlockData(fileJson)
  except Exception as ex:
    doAssert false, ex.msg

proc rpcExperimentalJsonMain*() =
  suite "rpc experimental json tests":
    let importFiles = [
      "block97.json", "block98.json", "block46147.json", "block46400.json",
      "block46402.json", "block47205.json", "block47216.json", "block48712.json",
      "block48915.json", "block49018.json", "block49439.json", "block49891.json",
      "block50111.json", "block78458.json", "block81383.json", "block81666.json",
      "block85858.json", "block146675.json", "block116524.json", "block196647.json",
      "block226147.json", "block226522.json", "block231501.json", "block243826.json",
      "block248032.json", "block299804.json", "block420301.json", "block512335.json",
      "block652148.json", "block668910.json", "block1017395.json", "block1149150.json",
      "block1155095.json", "block1317742.json", "block1352922.json",
      "block1368834.json", "block1417555.json", "block1431916.json",
      "block1487668.json", "block1920000.json", "block1927662.json",
      "block2463413.json", "block2675000.json", "block2675002.json", "block4370000.json",
    ]

    let
      RPC_HOST = "127.0.0.1"
      RPC_PORT = 0 # let the OS choose a port

    var
      rpcServer = newRpcHttpServerWithParams(initTAddress(RPC_HOST, RPC_PORT)).valueOr:
        echo "Failed to create RPC server: ", error
        quit(QuitFailure)
      client = newRpcHttpClient()

    rpcServer.start()
    waitFor client.connect(RPC_HOST, rpcServer.localAddress[0].port, secure = false)

    test "exp_getProofsByBlockNumber - latest block pre-execution state":
      for file in importFiles:
        let (com, parentStateRoot, _, _) = importBlockDataFromFile(file)

        setupExpRpc(com, rpcServer)

        let proofs = await client.exp_getProofsByBlockNumber("latest", false)

        checkAndValidateProofs(com.db, parentStateRoot, parentStateRoot, proofs)

    test "exp_getProofsByBlockNumber - latest block post-execution state":
      for file in importFiles:
        let (com, parentStateRoot, stateRoot, _) = importBlockDataFromFile(file)

        setupExpRpc(com, rpcServer)

        let proofs = await client.exp_getProofsByBlockNumber("latest", true)

        checkAndValidateProofs(com.db, parentStateRoot, stateRoot, proofs)

    test "exp_getProofsByBlockNumber - block by number pre-execution state":
      for file in importFiles:
        let
          (com, parentStateRoot, _, blockNumber) = importBlockDataFromFile(file)
          blockNum = blockId(blockNumber.truncate(uint64))

        setupExpRpc(com, rpcServer)

        let proofs = await client.exp_getProofsByBlockNumber(blockNum, false)

        checkAndValidateProofs(com.db, parentStateRoot, parentStateRoot, proofs)

    test "exp_getProofsByBlockNumber - block by number post-execution state":
      for file in importFiles:
        let
          (com, parentStateRoot, stateRoot, blockNumber) = importBlockDataFromFile(file)
          blockNum = blockId(blockNumber.truncate(uint64))

        setupExpRpc(com, rpcServer)

        let proofs = await client.exp_getProofsByBlockNumber(blockNum, true)

        checkAndValidateProofs(com.db, parentStateRoot, stateRoot, proofs)

    test "exp_getProofsByBlockNumber - block by number that doesn't exist":
      for file in importFiles:
        let
          (com, _, _, blockNumber) = importBlockDataFromFile(file)
          blockNum = blockId(blockNumber.truncate(uint64) + 1) # doesn't exist

        setupExpRpc(com, rpcServer)

        expect JsonRpcError:
          discard await client.exp_getProofsByBlockNumber(blockNum, false)

        expect JsonRpcError:
          discard await client.exp_getProofsByBlockNumber(blockNum, true)

    waitFor rpcServer.stop()
    waitFor rpcServer.closeWait()

when isMainModule:
  rpcExperimentalJsonMain()
