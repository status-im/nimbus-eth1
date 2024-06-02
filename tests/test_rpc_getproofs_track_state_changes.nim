# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This test is intended to be run manually against a running instance of Nimbus-Eth1
# so it should not be added to the test runner or to the CI test suite.
#
# It uses the exp_getProofsByBlockNumber endpoint to get the list of state updates
# for each block, it then applies these updates against a local test state and
# then checks the state root against the expected state root which is pulled from
# the block header. The local test state is persisted to disk so that the data can
# be re-used between separate test runs. The default database directory is the
# current directory but this can be changed by setting the DATABASE_PATH const below.
#
# To run the test:
# 1. Sync Nimbus up to or past the block number/s that you wish to test against.
#    You can use the premix persist tool to do this if Nimbus is not able to sync.
# 2. Start Nimbus with the http RPC-API enabled with the 'eth' and 'exp' namespaces
#    turned on using this command: build/nimbus --rpc --rpc-api=eth,exp
# 3. Start the test.

import
  std/tables,
  unittest2,
  web3/eth_api,
  json_rpc/rpcclient,
  stew/byteutils,
  ../nimbus/core/chain,
  ../nimbus/common/common,
  ../nimbus/rpc,
  ../nimbus/db/core_db,
  ../nimbus/db/core_db/persistent,
  ../nimbus/db/state_db/base,
  ../stateless/[witness_verification, witness_types],
  ./rpc/experimental_rpc_client

const
  RPC_HOST = "127.0.0.1"
  RPC_PORT = Port(8545)
  DATABASE_PATH = "."
  START_BLOCK = 330_000
  END_BLOCK = 1_000_000

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
      # Account doesn't exist:
      # The account was deleted due to a self destruct and the data no longer exists in the state.
      # The RPC API correctly returns zeroed values in this scenario which is the same behavior
      # implemented by geth.
      stateDB.setCode(address, @[])
      stateDB.clearStorage(address)
      stateDB.deleteAccount(address)
    elif (balance == 0 and nonce == 0 and codeHash == EMPTY_CODE_HASH and storageHash == EMPTY_ROOT_HASH):
      # Account exists but is empty:
      # The account was deleted due to a self destruct or the storage was cleared/set to zero
      # and the bytecode is empty.
      # The RPC API correctly returns codeHash == EMPTY_CODE_HASH and storageHash == EMPTY_ROOT_HASH
      # in this scenario which is the same behavior implemented by geth.
      stateDB.setCode(address, @[])
      stateDB.clearStorage(address)
      stateDB.setBalance(address, 0.u256)
      stateDB.setNonce(address, 0)
    else:
      # Account exists and is not empty:
      stateDB.setBalance(address, balance)
      stateDB.setNonce(address, nonce)
      for slotProof in slotProofs:
        stateDB.setStorage(address, slotProof.key, slotProof.value)

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

proc rpcGetProofsTrackStateChangesMain*() =

  suite "rpc getProofs track state changes tests":

    let client = newRpcHttpClient()
    waitFor client.connect(RPC_HOST, RPC_PORT, secure = false)

    test "Test tracking the changes introduced in every block":

      let com = CommonRef.new(newCoreDbRef(DefaultDbPersistent, DATABASE_PATH))
      com.initializeEmptyDb()

      let
        blockHeader = waitFor client.eth_getBlockByNumber(blockId(START_BLOCK), false)
        stateDB = newAccountStateDB(com.db, blockHeader.stateRoot.toHash256())

      for i in START_BLOCK..END_BLOCK:
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
