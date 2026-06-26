# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  ../db/core_db/memory_only,
  ../evm/[types, state],
  ../core/executor/process_block,
  ./[witness_types, witness_verification, stateless_types]

export witness_types, stateless_types, common, headers, blocks, results

func toExecutionWitness*(w: ExecutionWitnessWithKeys): ExecutionWitness =
  var res: ExecutionWitness
  for node in w.state:
    discard res.state.add(ByteList[MAX_BYTES_PER_WITNESS_NODE].init(node))
  for code in w.codes:
    discard res.codes.add(ByteList[MAX_BYTES_PER_CODE].init(code))
  for header in w.headers:
    discard res.headers.add(ByteList[MAX_BYTES_PER_HEADER].init(header))
  res

proc statelessProcessBlock*(
    witness: ExecutionWitness, com: CommonRef, blk: Block
): Result[void, string] =
  let
    verifiedHeaders = ?witness.verifyHeaders(blk.header)
      # Returns headers sorted by block number
    parent = verifiedHeaders[^1] # The last header is the parent
    preStateRoot = parent.stateRoot

  # Convert the list of trie nodes into a table keyed by node hash.
  var nodes: Table[Hash32, seq[byte]]
  for n in witness.state:
    nodes[keccak256(n.asSeq())] = n.asSeq()

  # Create an empty in memory database.
  let
    memoryDb = newCoreDbRef(DefaultDbMemory)
    memoryTxFrame = memoryDb.baseTxFrame()
  defer:
    memoryDb.close()

  # Load the subtrie of trie nodes (both account and storage tries) into the
  # in memory database.
  memoryTxFrame.putSubtrie(preStateRoot, nodes).isOkOr:
    return err("Unable to load subtrie: " & $error)
  doAssert memoryTxFrame.getStateRoot().get() == preStateRoot

  # Load the contract code into the database indexed by code hash.
  for c in witness.codes:
    doAssert memoryTxFrame.persistCodeByHash(keccak256(c.asSeq()), c.asSeq()).isOk()

  # Load the block hashes into the database indexed by block number.
  for h in verifiedHeaders:
    try:
      memoryTxFrame.addBlockNumberToHashLookup(h.number, h.computeRlpHash())
    except RlpError as e:
      raiseAssert e.msg

  # Create evm instance using the in memory database.
  let memoryVmState = BaseVMState()
  memoryVmState.init(
    parent, blk.header, com, memoryTxFrame, storeSlotHash = false,
    enableBalTracker = com.isAmsterdamOrLater(blk.header.timestamp))

  defer:
    memoryVmState.dispose()

  # Execute the block with all validations enabled
  ?memoryVmState.processBlock(
    blk,
    skipValidation = false,
    skipReceipts = false,
    skipUncles = true,
    skipStateRootCheck = false,
    skipPostExecBalCheck = not memoryVmState.balTrackerEnabled
  )
  doAssert memoryVmState.ledger.getStateRoot() == blk.header.stateRoot

  ok()

proc statelessProcessBlock*(
    witness: ExecutionWitness, id: NetworkId, config: ChainConfig, blk: Block
): Result[void, string] =
  let com = CommonRef.new(
    db = nil, config = config, networkId = id, initializeDb = false
  )
  statelessProcessBlock(witness, com, blk)

template statelessProcessBlock*(
    witness: ExecutionWitness, id: NetworkId, blk: Block
): Result[void, string] =
  statelessProcessBlock(witness, id, chainConfigForNetwork(id), blk)
