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
  web3/[eth_api_types, conversions],
  ../network/state/state_endpoints

template getOrRaise(stateNetwork: Opt[StateNetwork]): StateNetwork =
  let sn = stateNetwork.valueOr:
    raise newException(ValueError, "state sub-network not enabled")
  sn

proc installDebugApiHandlers*(rpcServer: RpcServer, stateNetwork: Opt[StateNetwork]) =
  rpcServer.rpc("debug_getBalanceByStateRoot") do(
    address: Address, stateRoot: Hash32
  ) -> UInt256:
    ## Returns the balance of the account of given address.
    ##
    ## address: address to check for balance.
    ## stateRoot: the state root used to search the state trie.
    ## Returns integer of the current balance in wei.

    let
      sn = stateNetwork.getOrRaise()
      balance = (await sn.getBalanceByStateRoot(stateRoot, address)).valueOr:
        raise newException(ValueError, "Unable to get balance")

    return balance

  rpcServer.rpc("debug_getTransactionCountByStateRoot") do(
    address: Address, stateRoot: Hash32
  ) -> Quantity:
    ## Returns the number of transactions sent from an address.
    ##
    ## address: address.
    ## stateRoot: the state root used to search the state trie.
    ## Returns integer of the number of transactions send from this address.

    let
      sn = stateNetwork.getOrRaise()
      nonce = (await sn.getTransactionCountByStateRoot(stateRoot, address)).valueOr:
        raise newException(ValueError, "Unable to get transaction count")

    return nonce.Quantity

  rpcServer.rpc("debug_getStorageAtByStateRoot") do(
    address: Address, slot: UInt256, stateRoot: Hash32
  ) -> FixedBytes[32]:
    ## Returns the value from a storage position at a given address.
    ##
    ## address: address of the storage.
    ## slot: integer of the position in the storage.
    ## stateRoot: the state root used to search the state trie.
    ## Returns: the value at this storage position.

    let
      sn = stateNetwork.getOrRaise()
      slotValue = (await sn.getStorageAtByStateRoot(stateRoot, address, slot)).valueOr:
        raise newException(ValueError, "Unable to get storage slot")

    return FixedBytes[32](slotValue.toBytesBE())

  rpcServer.rpc("debug_getCodeByStateRoot") do(
    address: Address, stateRoot: Hash32
  ) -> seq[byte]:
    ## Returns code at a given address.
    ##
    ## address: address
    ## stateRoot: the state root used to search the state trie.
    ## Returns the code from the given address.

    let
      sn = stateNetwork.getOrRaise()
      bytecode = (await sn.getCodeByStateRoot(stateRoot, address)).valueOr:
        raise newException(ValueError, "Unable to get code")

    return bytecode.asSeq()

  rpcServer.rpc("debug_getProofByStateRoot") do(
    address: Address, slots: seq[UInt256], stateRoot: Hash32
  ) -> ProofResponse:
    ## Returns information about an account and storage slots along with account
    ## and storage proofs which prove the existence of the values in the state.
    ##
    ## address: address of the account.
    ## slots: integers of the positions in the storage to return.
    ## stateRoot: the state root used to search the state trie.
    ## Returns: the proof response containing the account, account proof and storage proof

    let
      sn = stateNetwork.getOrRaise()
      proofs = (await sn.getProofsByStateRoot(stateRoot, address, slots)).valueOr:
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
      address: address,
      accountProof: seq[RlpEncodedBytes](proofs.accountProof),
      balance: proofs.account.balance,
      nonce: Quantity(proofs.account.nonce),
      codeHash: proofs.account.codeHash,
      storageHash: proofs.account.storageRoot,
      storageProof: storageProof,
    )
