# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[typetraits],
  json_rpc/rpcserver, stint, web3/conversions,
  eth/p2p,
  ../[transaction, vm_state, constants, vm_types],
  ../db/state_db,
  rpc_types, rpc_utils,
  ../core/tx_pool,
  ../common/common,
  ../utils/utils,
  ../beacon/web3_eth_conv,
  ./filters,
  ../core/executor/process_block,
  ../db/ledger,
  ../../stateless/witness_verification,
  ./p2p

type
  BlockHeader = eth_types.BlockHeader
  ReadOnlyStateDB = state_db.ReadOnlyStateDB

proc getBlockWitness*(
    com: CommonRef,
    blockHeader: BlockHeader): (KeccakHash, BlockWitness)
    {.raises: [BlockNotFound, RlpError, ValueError, CatchableError].} =
  # TODO: test behaviour of failure scenarios and improve error handling

  let
    chainDB = com.db
    blockHash = chainDB.getBlockHash(blockHeader.blockNumber)
    blockBody = chainDB.getBlockBody(blockHash)
    vmState = BaseVMState.new(blockHeader, com)

  vmState.generateWitness = true # Enable saving witness data

  # Execute the block of transactions and collect the keys of the touched account state
  let processBlockResult = processBlock(vmState, blockHeader, blockBody, commit = false)
  doAssert processBlockResult == ValidationResult.OK

  let mkeys = vmState.stateDB.makeMultiKeys()

  # Reset state to what it was before executing the block of transactions
  let initialState = BaseVMState.new(blockHeader, com)

  # Build witness using collected keys
  return (initialState.stateDB.rootHash, initialState.buildWitness(mkeys))

proc setupExpRpc*(com: CommonRef, server: RpcServer) =

  let chainDB = com.db

  proc getStateDB(header: BlockHeader): ReadOnlyStateDB =
    ## Retrieves the account db from canonical head
    # we don't use accounst_cache here because it's only read operations
    let ac = newAccountStateDB(chainDB, header.stateRoot, com.pruneTrie)
    result = ReadOnlyStateDB(ac)

  proc stateDBFromTag(quantityTag: BlockTag, readOnly = true): ReadOnlyStateDB
      {.gcsafe, raises: [CatchableError].} =
    result = getStateDB(chainDB.headerFromTag(quantityTag))

  server.rpc("exp_getBlockWitness") do(quantityTag: BlockTag) -> seq[byte]:
    ## Returns the block witness for a block by block number or tag.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## Returns seq[byte] or nil when no block was found.
    let
      blockHeader = headerFromTag(chainDB, quantityTag)
      (_, witness) = getBlockWitness(com, blockHeader)

    return witness

  server.rpc("exp_getBlockProofs") do(quantityTag: BlockTag) -> seq[ProofResponse]:
    ## Returns the block proofs for a block by block number or tag.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## Returns seq[byte] or nil when no block was found.

    let
      blockHeader = headerFromTag(chainDB, quantityTag)
      accDB = stateDBFromTag(quantityTag)
      (stateRoot, witness) = getBlockWitness(com, blockHeader)
      verifyWitnessResult = verifyWitness(stateRoot, witness)

    doAssert verifyWitnessResult.isOk()

    var blockProofs = newSeqOfCap[ProofResponse](verifyWitnessResult.value().len())

    for address, account in verifyWitnessResult.value():
      var slots = newSeqOfCap[UInt256](account.storage.len())

      for slotKey, slotValue in account.storage:
        slots.add(slotKey)

      blockProofs.add(getProof(accDB, address, slots))

    return blockProofs




