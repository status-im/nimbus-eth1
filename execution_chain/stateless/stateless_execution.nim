# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/tables,
  results,
  eth/common/[headers, blocks],
  eth/rlp,
  ../common/common,
  ../db/ledger,
  ../evm/[types, state],
  ../core/executor/process_block,
  ./[witness_types, witness_verification]

export witness_types, common, headers, blocks, results

proc statelessProcessBlock*(
    witness: ExecutionWitness, com: CommonRef, blk: Block
): Result[void, string] =
  let
    verifiedHeaders = ?witness.verifyHeaders(blk.header)
      # Returns headers sorted by block number
    parent = verifiedHeaders[^1] # The last header is the parent
    preStateRoot = parent.stateRoot

  # Verify the witness against the parent header stateroot.
  # This validates the state against the keys, the code and headers in the witness.
  ?witness.verifyState(preStateRoot)

  # Convert the list of trie nodes into a table keyed by node hash.
  var nodes: Table[Hash32, seq[byte]]
  for n in witness.state:
    nodes[keccak256(n)] = n

  # Create an empty in memory database.
  let
    memoryDb = newCoreDbRef(DefaultDbMemory)
    memoryTxFrame = memoryDb.baseTxFrame()

  # Load the subtrie of trie nodes (both account and storage tries) into the
  # in memory database.
  memoryTxFrame.putSubtrie(preStateRoot, nodes).isOkOr:
    return err("Unable to load subtrie: " & $error)
  doAssert memoryTxFrame.getStateRoot().get() == preStateRoot

  # Load the contract code into the database indexed by code hash.
  for c in witness.codes:
    doAssert memoryTxFrame.persistCodeByHash(keccak256(c), c).isOk()

  # Load the block hashes into the database indexed by block number.
  for h in verifiedHeaders:
    try:
      memoryTxFrame.addBlockNumberToHashLookup(h.number, h.computeRlpHash())
    except RlpError as e:
      raiseAssert e.msg

  # Create evm instance using the in memory database.
  let memoryVmState = BaseVMState()
  memoryVmState.init(parent, blk.header, com, memoryTxFrame, storeSlotHash = false)

  # Execute the block with all validations enabled
  ?memoryVmState.processBlock(
    blk,
    skipValidation = false,
    skipReceipts = false,
    skipUncles = true,
    skipStateRootCheck = false #,
    # taskpool = com.taskpool,
  )
  doAssert memoryVmState.ledger.getStateRoot() == blk.header.stateRoot

  ok()

proc statelessProcessBlock*(
    witness: ExecutionWitness, id: NetworkId, config: ChainConfig, blk: Block
): Result[void, string] =
  let com = CommonRef.new(
    db = nil, taskpool = nil, config = config, networkId = id, initializeDb = false
  )
  statelessProcessBlock(witness, com, blk)

template statelessProcessBlock*(
    witness: ExecutionWitness, id: NetworkId, blk: Block
): Result[void, string] =
  statelessProcessBlock(witness, id, chainConfigForNetwork(id), blk)
