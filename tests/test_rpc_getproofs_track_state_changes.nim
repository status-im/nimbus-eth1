# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, os, tables],
  unittest2,
  web3/eth_api,
  json_rpc/[rpcclient, rpcserver],
  stew/byteutils,
  ../nimbus/core/chain,
  ../nimbus/common/common,
  ../nimbus/rpc,
  ../../nimbus/db/[ledger, core_db],
  ../../nimbus/db/[core_db/persistent, storage_types],
  ../stateless/[witness_verification, witness_types],
  ./rpc/experimental_rpc_client

type
  Hash256 = eth_types.Hash256

func ethAddr*(x: Address): EthAddress =
  EthAddress x

template toHash256(hash: untyped): Hash256 =
  fromHex(Hash256, hash.toHex())


proc checkAndValidateWitnessAgainstProofs(
    db: CoreDbRef,
    parentStateRoot: Hash256,
    expectedStateRoot: Hash256,
    witness: seq[byte],
    proofs: seq[ProofResponse],
    stateDB: LedgerRef,
    i: uint64) =

  let
    verifyWitnessResult = verifyWitness(expectedStateRoot, witness, {wfNoFlag})

  check verifyWitnessResult.isOk()
  let witnessData = verifyWitnessResult.value()

  check:
    witness.len() > 0
    proofs.len() > 0
    witnessData.len() > 0

  for proof in proofs:
    let
      address = proof.address.ethAddr()
      balance = proof.balance
      nonce = proof.nonce.uint64
      codeHash = proof.codeHash.toHash256()
      storageHash = proof.storageHash.toHash256()
      slotProofs = proof.storageProof

    if witnessData.contains(address):
      let
        storageData = witnessData[address].storage
        code = witnessData[address].code

      check:
        witnessData[address].account.balance == balance
        witnessData[address].account.nonce == nonce
        witnessData[address].account.codeHash == codeHash

      for slotProof in slotProofs:
        if storageData.contains(slotProof.key):
          check storageData[slotProof.key] == slotProof.value

      #if code.len() > 0:
      stateDB.setCode(address, code)

    # stateDB.setBalance(address, balance)
    # stateDB.setNonce(address, nonce)

    # for slotProof in slotProofs:
    #   stateDB.setStorage(address, slotProof.key, slotProof.value)

    # # the account doesn't exist due to a self destruct
    # if (codeHash == ZERO_HASH256 and storageHash == ZERO_HASH256) or
    #     (balance == 0 and nonce == 0 and codeHash == EMPTY_SHA3 and storageHash == EMPTY_ROOT_HASH):
    #   stateDB.selfDestruct(address)

    # the account doesn't exist due to a self destruct
    if (codeHash == ZERO_HASH256 and storageHash == ZERO_HASH256):
      stateDB.selfDestruct(address)
    elif (balance == 0 and nonce == 0 and codeHash == EMPTY_SHA3 and storageHash == EMPTY_ROOT_HASH):
      stateDB.setBalance(address, balance)
      stateDB.setNonce(address, nonce)
      stateDB.clearStorage(address)
    else:
      stateDB.setBalance(address, balance)
      stateDB.setNonce(address, nonce)
      for slotProof in slotProofs:
        stateDB.setStorage(address, slotProof.key, slotProof.value)

    stateDB.persist(clearEmptyAccount = i >= 2_675_000, clearCache = false) # vmState.determineFork >= FkSpurious

    check stateDB.getBalance(address) == balance
    check stateDB.getNonce(address) == nonce

    if codeHash == ZERO_HASH256 or codeHash == EMPTY_SHA3:
      check stateDB.getCode(address).len() == 0
      check stateDB.getCodeHash(address) == EMPTY_SHA3
    else:
      check stateDB.getCodeHash(address) == codeHash

    if storageHash == ZERO_HASH256 or storageHash == EMPTY_ROOT_HASH:
      check stateDB.getStorageRoot(address) == EMPTY_ROOT_HASH
    else:
      check stateDB.getStorageRoot(address) == storageHash

  check stateDB.rootHash == expectedStateRoot


proc rpcExperimentalJsonMain*() =

  suite "rpc getProofs track state changes tests":

    let
      RPC_HOST = "127.0.0.1"
      RPC_PORT = 0 # let the OS choose a port

    var client = newRpcHttpClient()

    waitFor client.connect(RPC_HOST, Port(8545), secure = false)

    test "Test track the changes introduced in every block":

      let com = CommonRef.new(
        newCoreDbRef(LegacyDbPersistent, "."), false)

      com.initializeEmptyDb()
      com.db.compensateLegacySetup()

      let startBlock = 190_000 # 116_525
      let endBlock = 200_000
      let blockHeader = waitFor client.eth_getBlockByNumber(blockId(startBlock.uint64), false)

      var stateDB = AccountsCache.init(com.db, blockHeader.stateRoot.toHash256(), false)

      for i in startBlock..endBlock:
        let
          blockNum = blockId(i.uint64)
          parentHeader = waitFor client.eth_getBlockByNumber(blockId(i.uint64 - 1), false)
          blockHeader = waitFor client.eth_getBlockByNumber(blockId(i.uint64), false)
          witness = waitFor client.exp_getWitnessByBlockNumber(blockNum, true)
          proofs = waitFor client.exp_getProofsByBlockNumber(blockNum, true)
        checkAndValidateWitnessAgainstProofs(
          com.db, parentHeader.stateRoot.toHash256(), blockHeader.stateRoot.toHash256(), witness, proofs, stateDB, i.uint64)

        if i mod 10000 == 0:
          let blockHeader = waitFor client.eth_getBlockByNumber(blockNum, false)

          for p in proofs:
            let address = p.address.ethAddr
            discard stateDB.accountExists(address)

          stateDB.persist(clearEmptyAccount = i >= 2_675_000, clearCache = true) # vmState.determineFork >= FkSpurious

          echo "Block Number = ", i, " Current State Root = ", stateDB.rootHash
          echo "Expected block stateRoot: ", blockHeader.stateRoot
          doAssert blockHeader.stateRoot.toHash256() == stateDB.rootHash


when isMainModule:
  rpcExperimentalJsonMain()
