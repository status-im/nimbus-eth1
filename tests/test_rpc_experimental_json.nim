# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, os, tables],
  asynctest,
  json_rpc/[rpcclient, rpcserver],
  stew/byteutils,
  ../nimbus/core/chain,
  ../nimbus/common/common,
  ../nimbus/rpc,
  ../../nimbus/db/[ledger, core_db],
  ../stateless/[witness_verification, witness_types],
  ./rpc/experimental_rpc_client

type
  Hash256 = eth_types.Hash256

func ethAddr*(x: Address): EthAddress =
  EthAddress x

template toHash256(hash: untyped): Hash256 =
  fromHex(Hash256, hash.toHex())

proc importBlockData(node: JsonNode): (CommonRef, Hash256, Hash256, UInt256) {. raises: [Exception].} =
  var
    blockNumber = UInt256.fromHex(node["blockNumber"].getStr())
    memoryDB    = newCoreDbRef LegacyDbMemory
    config      = chainConfigForNetwork(MainNet)
    com         = CommonRef.new(memoryDB, config, pruneTrie = false)
    state       = node["state"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.kvt.put(key, value)

  let
    parentNumber = blockNumber - 1
    parent = com.db.getBlockHeader(parentNumber)
    header = com.db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = com.db.getBlockBody(headerHash)
    chain = newChain(com)
    headers = @[header]
    bodies = @[blockBody]

  # it's ok if setHead fails here because of missing ancestors
  discard com.db.setHead(parent, true)
  let validationResult = chain.persistBlocks(headers, bodies)
  doAssert validationResult == ValidationResult.OK

  return (com, parent.stateRoot, header.stateRoot, blockNumber)

proc checkAndValidateWitnessAgainstProofs(
    db: CoreDbRef,
    parentStateRoot: KeccakHash,
    expectedStateRoot: KeccakHash,
    witness: seq[byte],
    proofs: seq[ProofResponse]) =

  let
    stateDB = AccountsCache.init(db, parentStateRoot, false)
    verifyWitnessResult = verifyWitness(expectedStateRoot, witness, {wfNoFlag})

  check verifyWitnessResult.isOk()
  let witnessData = verifyWitnessResult.value()

  check:
    witness.len() > 0
    proofs.len() > 0
    witnessData.len() > 0
    witnessData.len() == proofs.len()

  for proof in proofs:
    let
      address = proof.address.ethAddr()
      slotProofs = proof.storageProof
      storageData = witnessData[address].storage
      code = witnessData[address].code

    check:
      witnessData.contains(address)
      witnessData[address].account.balance == proof.balance
      witnessData[address].account.nonce == proof.nonce.uint64
      witnessData[address].account.codeHash == proof.codeHash.toHash256()
      storageData.len() == slotProofs.len()

    stateDB.setBalance(address, proof.balance)
    stateDB.setNonce(address, proof.nonce.uint64)

    if code.len() > 0:
      stateDB.setCode(address, code)

    for slotProof in slotProofs:
      check:
        storageData.contains(slotProof.key)
        storageData[slotProof.key] == slotProof.value
      stateDB.setStorage(address, slotProof.key, slotProof.value)

    check:
      stateDB.getBalance(address) == proof.balance
      stateDB.getNonce(address) == proof.nonce.uint64
      stateDB.getCodeHash(address) == proof.codeHash.toHash256()
      stateDB.getStorageRoot(address) == proof.storageHash.toHash256()

  stateDB.persist()

  check:
    stateDB.rootHash == expectedStateRoot

proc importBlockDataFromFile(file: string): (CommonRef, Hash256, Hash256, UInt256) {. raises: [].} =
  try:
    let
      fileJson = json.parseFile("tests" / "fixtures" / "PersistBlockTests" / file)
    return importBlockData(fileJson)
  except Exception as ex:
    doAssert false, ex.msg

proc rpcExperimentalJsonMain*() =

  suite "rpc experimental json tests":

    let importFiles = [
      "block97.json",
      "block98.json",
      "block46147.json",
      "block46400.json",
      "block46402.json",
      "block47205.json",
      "block47216.json",
      "block48712.json",
      "block48915.json",
      "block49018.json",
      "block49439.json",
      "block49891.json",
      "block50111.json",
      "block78458.json",
      "block81383.json",
      "block81666.json",
      "block85858.json",
      "block146675.json",
      "block116524.json",
      "block196647.json",
      "block226147.json",
      "block226522.json",
      "block231501.json",
      "block243826.json",
      "block248032.json",
      "block299804.json",
      "block420301.json",
      "block512335.json",
      "block652148.json",
      "block668910.json",
      "block1017395.json",
      "block1149150.json",
      "block1155095.json",
      "block1317742.json",
      "block1352922.json",
      "block1368834.json",
      "block1417555.json",
      "block1431916.json",
      "block1487668.json",
      "block1920000.json",
      "block1927662.json",
      "block2463413.json",
      "block2675000.json",
      "block2675002.json",
      "block4370000.json"
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


    test "exp_getWitnessByBlockNumber and exp_getProofsByBlockNumber - latest block pre-execution state":
      for file in importFiles:
        let (com, parentStateRoot, _, _) = importBlockDataFromFile(file)

        setupExpRpc(com, rpcServer)

        let
          witness = await client.exp_getWitnessByBlockNumber("latest", false)
          proofs = await client.exp_getProofsByBlockNumber("latest", false)

        checkAndValidateWitnessAgainstProofs(com.db, parentStateRoot, parentStateRoot, witness, proofs)

    test "exp_getWitnessByBlockNumber and exp_getProofsByBlockNumber - latest block post-execution state":
      for file in importFiles:
        let (com, parentStateRoot, stateRoot, _) = importBlockDataFromFile(file)

        setupExpRpc(com, rpcServer)

        let
          witness = await client.exp_getWitnessByBlockNumber("latest", true)
          proofs = await client.exp_getProofsByBlockNumber("latest", true)

        checkAndValidateWitnessAgainstProofs(com.db, parentStateRoot, stateRoot, witness, proofs)

    test "exp_getWitnessByBlockNumber and exp_getProofsByBlockNumber - block by number pre-execution state":
      for file in importFiles:
        let
          (com, parentStateRoot, _, blockNumber) = importBlockDataFromFile(file)
          blockNum = blockId(blockNumber.truncate(uint64))

        setupExpRpc(com, rpcServer)

        let
          witness = await client.exp_getWitnessByBlockNumber(blockNum, false)
          proofs = await client.exp_getProofsByBlockNumber(blockNum, false)

        checkAndValidateWitnessAgainstProofs(com.db, parentStateRoot, parentStateRoot, witness, proofs)

    test "exp_getWitnessByBlockNumber and exp_getProofsByBlockNumber - block by number post-execution state":
      for file in importFiles:
        let
          (com, parentStateRoot, stateRoot, blockNumber) = importBlockDataFromFile(file)
          blockNum = blockId(blockNumber.truncate(uint64))

        setupExpRpc(com, rpcServer)

        let
          witness = await client.exp_getWitnessByBlockNumber(blockNum, true)
          proofs = await client.exp_getProofsByBlockNumber(blockNum, true)

        checkAndValidateWitnessAgainstProofs(com.db, parentStateRoot, stateRoot, witness, proofs)

    test "exp_getWitnessByBlockNumber and exp_getProofsByBlockNumber - block by number that doesn't exist":
      for file in importFiles:
        let
          (com, _, _, blockNumber) = importBlockDataFromFile(file)
          blockNum = blockId(blockNumber.truncate(uint64) + 1) # doesn't exist

        setupExpRpc(com, rpcServer)

        expect JsonRpcError:
          discard await client.exp_getWitnessByBlockNumber(blockNum, false)

        expect JsonRpcError:
          discard await client.exp_getProofsByBlockNumber(blockNum, false)

        expect JsonRpcError:
          discard await client.exp_getWitnessByBlockNumber(blockNum, true)

        expect JsonRpcError:
          discard await client.exp_getProofsByBlockNumber(blockNum, true)

    test "Contract storage updated - bytecode should exist in witness":
      for file in importFiles:
        let
          (com, parentStateRoot, stateRoot, blockNumber) = importBlockDataFromFile(file)
          blockNum = blockId(blockNumber.truncate(uint64))

        setupExpRpc(com, rpcServer)

        let
          witness = await client.exp_getWitnessByBlockNumber(blockNum, false)
          proofs = await client.exp_getProofsByBlockNumber(blockNum, true)
          verifyWitnessResult = verifyWitness(parentStateRoot, witness, {wfNoFlag})

        check verifyWitnessResult.isOk()
        let witnessData = verifyWitnessResult.value()

        for proof in proofs:
          let address = ethAddr(proof.address)
          # if the storage was updated on an existing contract
          if proof.storageProof.len() > 0 and witnessData.contains(address):
            check witnessData[address].code.len() > 0

    waitFor rpcServer.stop()
    waitFor rpcServer.closeWait()

when isMainModule:
  rpcExperimentalJsonMain()
