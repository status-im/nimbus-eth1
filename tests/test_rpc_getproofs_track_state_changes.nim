# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/tables,
  unittest2,
  web3/eth_api,
  json_rpc/rpcclient,
  stew/byteutils,
  ../nimbus/core/chain,
  ../nimbus/common/common,
  ../nimbus/rpc,
  ../../nimbus/db/[core_db, core_db/persistent, state_db/base],
  ../stateless/[witness_verification, witness_types],
  ./rpc/experimental_rpc_client

type
  Hash256 = eth_types.Hash256

template ethAddr*(x: Address): EthAddress =
  EthAddress x

template toHash256(hash: untyped): Hash256 =
  fromHex(Hash256, hash.toHex())

proc updateStateUsingProofsAndCheckStateRoot(
    stateDB: AccountStateDB,
    expectedStateRoot: Hash256,
    witness: seq[byte],
    proofs: seq[ProofResponse]) =

  let verifyWitnessResult = verifyWitness(expectedStateRoot, witness, {wfNoFlag})
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

      if code.len() > 0:
        stateDB.setCode(address, code)

    if (balance == 0 and nonce == 0 and codeHash == ZERO_HASH256 and storageHash == ZERO_HASH256):
      stateDB.setCode(address, @[])
      stateDB.clearStorage(address)
      stateDB.deleteAccount(address)
    elif (balance == 0 and nonce == 0 and codeHash == EMPTY_SHA3 and storageHash == EMPTY_ROOT_HASH):
      stateDB.setCode(address, @[])
      stateDB.clearStorage(address)
      stateDB.setBalance(address, 0.u256)
      stateDB.setNonce(address, 0)
      stateDB.clearStorage(address)
    else:
      stateDB.setBalance(address, balance)
      stateDB.setNonce(address, nonce)
      for slotProof in slotProofs:
        stateDB.setStorage(address, slotProof.key, slotProof.value)

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

proc rpcGetProofsTrackStateChangesMain*() =

  suite "rpc getProofs track state changes tests":

    const
      RPC_HOST = "127.0.0.1"
      RPC_PORT = Port(8545)
      DATABASE_PATH = "."

    let client = newRpcHttpClient()
    waitFor client.connect(RPC_HOST, RPC_PORT, secure = false)

    test "Test tracking the changes introduced in every block":

      let com = CommonRef.new(newCoreDbRef(LegacyDbPersistent, DATABASE_PATH), false)
      com.initializeEmptyDb()
      com.db.compensateLegacySetup()

      let
        startBlock = 644_000
        endBlock = 1_000_000
        blockHeader = waitFor client.eth_getBlockByNumber(blockId(startBlock.uint64), false)
        stateDB = newAccountStateDB(com.db, blockHeader.stateRoot.toHash256(), false)

      for i in startBlock..endBlock:
        let
          blockNum = blockId(i.uint64)
          blockHeader: BlockObject = waitFor client.eth_getBlockByNumber(blockNum, false)
          witness = waitFor client.exp_getWitnessByBlockNumber(blockNum, true)
          proofs = waitFor client.exp_getProofsByBlockNumber(blockNum, true)

        updateStateUsingProofsAndCheckStateRoot(
            stateDB,
            blockHeader.stateRoot.toHash256(),
            witness,
            proofs)

        if i mod 1000 == 0:
          echo "Block number: ", i
          echo "Expected block stateRoot: ", blockHeader.stateRoot
          echo "Actual block stateRoot: ", stateDB.rootHash
          doAssert blockHeader.stateRoot.toHash256() == stateDB.rootHash

when isMainModule:
  rpcGetProofsTrackStateChangesMain()
