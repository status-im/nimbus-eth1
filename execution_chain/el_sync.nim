# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Consensus to execution syncer prototype based on nrpc

{.push raises: [].}

import
  chronos,
  chronicles,
  web3,
  web3/[engine_api, primitives, conversions],
  beacon_chain/consensus_object_pools/blockchain_dag,
  beacon_chain/el/[el_manager, engine_api_conversions],
  beacon_chain/spec/[forks, presets, state_transition_block]

logScope:
  topics = "elsync"

proc getForkedBlock(dag: ChainDAGRef, slot: Slot): Opt[ForkedTrustedSignedBeaconBlock] =
  let bsi = ?dag.getBlockIdAtSlot(slot)
  if bsi.isProposed():
    dag.getForkedBlock(bsi.bid)
  else:
    Opt.none(ForkedTrustedSignedBeaconBlock)

proc blockNumber(blck: ForkedTrustedSignedBeaconBlock): uint64 =
  withBlck(blck):
    when consensusFork >= ConsensusFork.Bellatrix and consensusFork < ConsensusFork.Gloas:
      forkyBlck.message.body.execution_payload.block_number
    else:
      0'u64

# Load the network configuration based on the network id
proc loadNetworkConfig(cfg: RuntimeConfig): (uint64, uint64) =
  case cfg.CONFIG_NAME
  of "mainnet":
    (15537393'u64, 4700013'u64)
  of "sepolia":
    (1450408'u64, 115193'u64)
  of "holesky", "hoodi":
    (0'u64, 0'u64)
  else:
    notice "Loading custom network, assuming post-merge"
    (0'u64, 0'u64)

# Slot Finding Mechanism
# First it sets the initial lower bound to `firstSlotAfterMerge` + number of blocks after Era1
# Then it iterates over the slots to find the current slot number, along with reducing the
# search space by calculating the difference between the `blockNumber` and the `block_number` from the executionPayload
# of the slot, then adding the difference to the importedSlot. This pushes the lower bound more,
# making the search way smaller
proc findSlot(
    dag: ChainDAGRef,
    elBlockNumber: uint64,
    lastEra1Block: uint64,
    firstSlotAfterMerge: uint64,
): Opt[uint64] =
  var importedSlot = (elBlockNumber - lastEra1Block) + firstSlotAfterMerge + 1
  debug "Finding slot number corresponding to block", elBlockNumber, importedSlot

  var clNum = 0'u64
  while clNum < elBlockNumber:
    # Check if we can get the block id - if not, this part of the chain is not
    # available from the CL
    let bsi = ?dag.getBlockIdAtSlot(Slot(importedSlot))

    if not bsi.isProposed:
      importedSlot += 1
      continue # Empty slot

    let blck = dag.getForkedBlock(bsi.bid).valueOr:
      return # Block unavailable

    clNum = blck.blockNumber
    # on the first iteration, the arithmetic helps skip the gap that has built
    # up due to empty slots - for all subsequent iterations, except the last,
    # we'll go one step at a time
    # iteration so that we don't start at "one slot early"
    importedSlot += max(elBlockNumber - clNum, 1)

  Opt.some importedSlot

proc syncToEngineApi*(dag: ChainDAGRef, url: EngineApiUrl) {.async.} =
  # Takes blocks from the CL and sends them to the EL - the attempt is made
  # optimistically until something unexpected happens (reorg etc) at which point
  # the process ends

  let
    # Create the client for the engine api
    # And exchange the capabilities for a test communication
    web3 = await url.newWeb3()
    rpcClient = web3.provider
    (lastEra1Block, firstSlotAfterMerge) = dag.cfg.loadNetworkConfig()

  defer:
    try:
      await web3.close()
    except:
      discard

  # Load the EL state detials and create the beaconAPI client
  var elBlockNumber = uint64(await rpcClient.eth_blockNumber())

  # Check for pre-merge situation
  if elBlockNumber <= lastEra1Block:
    debug "EL still pre-merge, no EL sync",
      blocknumber = elBlockNumber, lastPoWBlock = lastEra1Block
    return

  # Load the latest state from the CL
  var clBlockNumber = block:
    let blck = dag.getForkedBlock(dag.head.slot).valueOr:
      # When starting from a checkpoint, the CL might not yet have the head
      # block in the database
      debug "CL has not yet downloaded head block", head = dag.head
      return
    blck.blockNumber

  # Check if the EL is already in sync or about to become so (ie processing a
  # payload already, most likely)
  if clBlockNumber in [elBlockNumber, elBlockNumber + 1]:
    debug "EL in sync (or almost)", clBlockNumber, elBlockNumber
    return

  if clBlockNumber < elBlockNumber:
    # This happens often during initial sync when the light client information
    # allows the EL to sync ahead of the CL head - it can also happen during
    # reorgs
    debug "CL is behind EL, not activating", clBlockNumber, elBlockNumber
    return

  var importedSlot = findSlot(dag, elBlockNumber, lastEra1Block, firstSlotAfterMerge).valueOr:
    debug "Missing slot information for sync", elBlockNumber
    return

  notice "Found initial slot for EL sync", importedSlot, elBlockNumber, clBlockNumber

  while elBlockNumber < clBlockNumber:
    var isAvailable = false
    let curBlck = dag.getForkedBlock(Slot(importedSlot)).valueOr:
      importedSlot += 1
      continue
    importedSlot += 1
    let payloadResponse = withBlck(curBlck):
      # Don't include blocks before bellatrix, as it doesn't have payload
      when consensusFork >= ConsensusFork.Gloas:
        break
      elif consensusFork >= ConsensusFork.Bellatrix:
        # Load the execution payload for all blocks after the bellatrix upgrade
        let payload =
          forkyBlck.message.body.execution_payload.asEngineExecutionPayload()

        debug "Sending payload", payload

        when consensusFork >= ConsensusFork.Electra:
          let
            # Calculate the versioned hashes from the kzg commitments
            versioned_hashes =
              forkyBlck.message.body.blob_kzg_commitments.asEngineVersionedHashes()
            # Execution Requests for Electra
            execution_requests =
              forkyBlck.message.body.execution_requests.asEngineExecutionRequests()

          await rpcClient.engine_newPayloadV4(
            payload,
            versioned_hashes,
            forkyBlck.message.parent_root.to(Hash32),
            execution_requests,
          )
        elif consensusFork >= ConsensusFork.Deneb:
          # Calculate the versioned hashes from the kzg commitments
          let versioned_hashes =
            forkyBlck.message.body.blob_kzg_commitments.asEngineVersionedHashes()
          await rpcClient.engine_newPayloadV3(
            payload, versioned_hashes, forkyBlck.message.parent_root.to(Hash32)
          )
        elif consensusFork >= ConsensusFork.Capella:
          await rpcClient.engine_newPayloadV2(payload)
        else:
          await rpcClient.engine_newPayloadV1(payload)
      else:
        return

    if payloadResponse.status != PayloadExecutionStatus.valid:
      if payloadResponse.status notin
          [PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted]:
        # This would be highly unusual since it would imply a CL-valid but
        # EL-invalid block..
        warn "Payload invalid",
          elBlockNumber, status = payloadResponse.status, curBlck = shortLog(curBlck)
      return

    debug "newPayload accepted", elBlockNumber, response = payloadResponse.status

    elBlockNumber += 1

    if elBlockNumber mod 1024 == 0:
      let curElBlock = uint64(await rpcClient.eth_blockNumber())
      if curElBlock != elBlockNumber:
        # If the EL starts syncing on its own, faster than we can feed it blocks
        # from here, it'll run ahead and we can stop this remote-drive attempt
        # TODO this happens because el-sync competes with the regular devp2p sync
        #      when in fact it could be collaborating such that we don't do
        #      redundant work
        debug "EL out of sync with EL syncer", curElBlock, elBlockNumber
        return
