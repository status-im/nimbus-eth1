# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_rpc/rpcserver,
  chronicles,
  web3/conversions, # sigh, for FixedBytes marshalling
  web3/eth_api_types,
  web3/primitives as web3types,
  eth/common/eth_types,
  ../common/common_utils,
  ../network/state/state_endpoints

proc installDebugApiHandlers*(rpcServer: RpcServer, stateNetwork: Opt[StateNetwork]) =
  rpcServer.rpc("debug_getBalanceByStateRoot") do(
    data: web3Types.Address, stateRoot: web3types.Hash256
  ) -> UInt256:
    ## Returns the balance of the account of given address.
    ##
    ## data: address to check for balance.
    ## stateRoot: the state root used to search the state trie.
    ## Returns integer of the current balance in wei.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let balance = (
      await sn.getBalanceByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get balance")

    return balance

  rpcServer.rpc("debug_getTransactionCountByStateRoot") do(
    data: web3Types.Address, stateRoot: web3types.Hash256
  ) -> Quantity:
    ## Returns the number of transactions sent from an address.
    ##
    ## data: address.
    ## stateRoot: the state root used to search the state trie.
    ## Returns integer of the number of transactions send from this address.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let nonce = (
      await sn.getTransactionCountByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get transaction count")
    return nonce.Quantity

  rpcServer.rpc("debug_getStorageAtByStateRoot") do(
    data: web3Types.Address, slot: UInt256, stateRoot: web3types.Hash256
  ) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    ##
    ## data: address of the storage.
    ## slot: integer of the position in the storage.
    ## stateRoot: the state root used to search the state trie.
    ## Returns: the value at this storage position.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let slotValue = (
      await sn.getStorageAtByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress, slot
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get storage slot")
    return FixedBytes[32](slotValue.toBytesBE())

  rpcServer.rpc("debug_getCodeByStateRoot") do(
    data: web3Types.Address, stateRoot: web3types.Hash256
  ) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## data: address
    ## stateRoot: the state root used to search the state trie.
    ## Returns the code from the given address.

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let bytecode = (
      await sn.getCodeByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get code")

    return bytecode.asSeq()

  rpcServer.rpc("debug_getProofByStateRoot") do(
    data: web3Types.Address, slots: seq[UInt256], stateRoot: web3types.Hash256
  ) -> ProofResponse:
    ## Returns information about an account and storage slots along with account
    ## and storage proofs which prove the existence of the values in the state.
    ##
    ## data: address of the account.
    ## slots: integers of the positions in the storage to return.
    ## stateRoot: the state root used to search the state trie.
    ## Returns: the proof response containing the account, account proof and storage proof

    let sn = stateNetwork.valueOr:
      raise newException(ValueError, "State sub-network not enabled")

    let proofs = (
      await sn.getProofsByStateRoot(
        KeccakHash.fromBytes(stateRoot.bytes()), data.EthAddress, slots
      )
    ).valueOr:
      raise newException(ValueError, "Unable to get proofs")

    var storageProof = newSeqOfCap[StorageProof](slots.len)
    for i, slot in slots:
      let (slotKey, slotValue) = proofs.slots[i]
      storageProof.add(
        StorageProof(
          key: slotKey,
          value: slotValue,
          proof: seq[RlpEncodedBytes](proofs.slotProofs[i]),
        )
      )

    return ProofResponse(
      address: data,
      accountProof: seq[RlpEncodedBytes](proofs.accountProof),
      balance: proofs.account.balance,
      nonce: web3types.Quantity(proofs.account.nonce),
      codeHash: web3types.Hash256(proofs.account.codeHash.data),
      storageHash: web3types.Hash256(proofs.account.storageRoot.data),
      storageProof: storageProof,
    )
