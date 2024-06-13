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
  ../common/common,
  ../utils/utils,
  ../beacon/web3_eth_conv,
  ./filters,
  ../core/executor/process_block,
  ../db/ledger,
  ../stateless/multi_keys,
  ./p2p

type
  BlockHeader = eth_types.BlockHeader
  ReadOnlyStateDB = state_db.ReadOnlyStateDB

proc getMultiKeys*(
    com: CommonRef,
    blockHeader: BlockHeader,
    statePostExecution: bool): MultiKeysRef
    {.raises: [RlpError, BlockNotFound, ValueError, CatchableError].} =

  let
    chainDB = com.db
    blk = chainDB.getEthBlock(blockHeader.number)
    # Initializing the VM will throw a Defect if the state doesn't exist.
    # Once we enable pruning we will need to check if the block state has been pruned
    # before trying to initialize the VM as we do here.
    vmState = BaseVMState.new(blk.header, com).valueOr:
                raise newException(ValueError, "Cannot create vm state")

  vmState.collectWitnessData = true # Enable saving witness data
  vmState.com.hardForkTransition(blockHeader)

  let dbTx = vmState.com.db.newTransaction()
  defer: dbTx.dispose()

  # Execute the block of transactions and collect the keys of the touched account state
  processBlock(vmState, blk).expect("success")

  let mkeys = vmState.stateDB.makeMultiKeys()

  dbTx.rollback()

  mkeys

proc getBlockProofs*(
    accDB: ReadOnlyStateDB,
    mkeys: MultiKeysRef): seq[ProofResponse] {.raises: [RlpError].} =

  var blockProofs = newSeq[ProofResponse]()

  for keyData in mkeys.keys:
    let address = keyData.address
    var slots = newSeq[UInt256]()

    if not keyData.storageKeys.isNil and accDB.accountExists(address):
      for slotData in keyData.storageKeys.keys:
        slots.add(fromBytesBE(UInt256, slotData.storageSlot))

    blockProofs.add(getProof(accDB, address, slots))

  return blockProofs

proc setupExpRpc*(com: CommonRef, server: RpcServer) =

  let chainDB = com.db

  proc getStateDB(header: BlockHeader): ReadOnlyStateDB =
    ## Retrieves the account db from canonical head
    # we don't use accounst_cache here because it's only read operations
    let ac = newAccountStateDB(chainDB, header.stateRoot)
    result = ReadOnlyStateDB(ac)

  server.rpc("exp_getProofsByBlockNumber") do(quantityTag: BlockTag, statePostExecution: bool) -> seq[ProofResponse]:
    ## Returns the block proofs for a block by block number or tag.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## statePostExecution: bool which indicates whether to return the proofs based on the state before or after executing the block.
    ## Returns seq[ProofResponse]

    let
      blockHeader = chainDB.headerFromTag(quantityTag)
      mkeys = getMultiKeys(com, blockHeader, statePostExecution)

    let accDB = if statePostExecution:
      getStateDB(blockHeader)
    else:
      getStateDB(chainDB.getBlockHeader(blockHeader.parentHash))

    return getBlockProofs(accDB, mkeys)
