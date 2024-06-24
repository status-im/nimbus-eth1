# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strutils,
  chronicles,
  eth/common/eth_types_rlp,
  ./engine_spec,
  ../cancun/customizer

# Corrupt the hash of a valid payload, client should reject the payload.
# All possible scenarios:
#    (fcU)
# ┌────────┐        ┌────────────────────────┐
# │  HEAD  │◄───────┤ Bad Hash (!Sync,!Side) │
# └────┬───┘        └────────────────────────┘
#    │
#    │
# ┌────▼───┐        ┌────────────────────────┐
# │ HEAD-1 │◄───────┤ Bad Hash (!Sync, Side) │
# └────┬───┘        └────────────────────────┘
#    │
#
#
#   (fcU)
# ********************  ┌───────────────────────┐
# *  (Unknown) HEAD  *◄─┤ Bad Hash (Sync,!Side) │
# ********************  └───────────────────────┘
#    │
#    │
# ┌────▼───┐            ┌───────────────────────┐
# │ HEAD-1 │◄───────────┤ Bad Hash (Sync, Side) │
# └────┬───┘            └───────────────────────┘
#    │
#

type
  BadHashOnNewPayload* = ref object of EngineSpec
    syncing*:   bool
    sidechain*: bool

  Shadow = ref object
    payload: ExecutableData

method withMainFork(cs: BadHashOnNewPayload, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: BadHashOnNewPayload): string =
  "Bad Hash on NewPayload (syncing=$1, sidechain=$1)" % [$cs.syncing, $cs.sidechain]

method execute(cs: BadHashOnNewPayload, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  var shadow = Shadow()

  var pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Alter hash on the payload and send it to client, should produce an error
      shadow.payload = env.clMock.latestExecutableData
      var invalidHash = ethHash shadow.payload.blockHash
      invalidHash.data[^1] = byte(255 - invalidHash.data[^1])
      shadow.payload.blockHash = w3Hash invalidHash

      if not cs.syncing and cs.sidechain:
        # We alter the payload by setting the parent to a known past block in the
        # canonical chain, which makes this payload a side chain payload, and also an invalid block hash
        # (because we did not update the block hash appropriately)
        shadow.payload.parentHash = w3Hash env.clMock.latestHeader.parentHash
      elif cs.syncing:
        # We need to send an fcU to put the client in syncing state.
        let
          randomHeadBlock = Web3Hash.randomBytes()
          latestHash = w3Hash env.clMock.latestHeader.blockHash
          fcU = ForkchoiceStateV1(
            headblockHash:      randomHeadBlock,
            safeblockHash:      latestHash,
            finalizedblockHash: latestHash,
          )
          version = env.engine.version(env.clMock.latestHeader.timestamp)
          r = env.engine.client.forkchoiceUpdated(version, fcU)

        r.expectPayloadStatus(PayloadExecutionStatus.syncing)

        if cs.sidechain:
          # syncing and sidechain, the caonincal head is an unknown payload to us,
          # but this specific bad hash payload is in theory part of a side chain.
          # Therefore the parent we use is the head hash.
          shadow.payload.parentHash = latestHash
        else:
          # The invalid bad-hash payload points to the unknown head, but we know it is
          # indeed canonical because the head was set using forkchoiceUpdated.
          shadow.payload.parentHash = randomHeadBlock

      # Execution specification::
      # - (status: INVALID_BLOCK_HASH, latestValidHash: null, validationError: null) if the blockHash validation has failed
      # Starting from Shanghai, INVALID should be returned instead (https:#githucs.com/ethereum/execution-apis/pull/338)
      let
        version = env.engine.version(shadow.payload.timestamp)
        r = env.engine.client.newPayload(version, shadow.payload)

      if version >= Version.V2:
        r.expectStatus(PayloadExecutionStatus.invalid)
      else:
        r.expectStatusEither([PayloadExecutionStatus.invalidBlockHash, PayloadExecutionStatus.invalid])

      r.expectLatestValidHash()
      return true
  ))
  testCond pbRes

  # Lastly, attempt to build on top of the invalid payload
  pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      var customizer = CustomPayloadData(
        parentHash: Opt.some(ethHash shadow.payload.blockHash),
      )
      shadow.payload = customizer.customizePayload(env.clMock.latestExecutableData)

      # Response status can be ACCEPTED (since parent payload could have been thrown out by the client)
      # or INVALID (client still has the payload and can verify that this payload is incorrectly building on top of it),
      # but a VALID response is incorrect.
      let
        version = env.engine.version(shadow.payload.timestamp)
        r = env.engine.client.newPayload(version, shadow.payload)
      r.expectStatusEither([PayloadExecutionStatus.accepted, PayloadExecutionStatus.invalid, PayloadExecutionStatus.syncing])
      return true
  ))

  testCond pbRes
  return true

type
  ParentHashOnNewPayload* = ref object of EngineSpec
    syncing*: bool

method withMainFork(cs: ParentHashOnNewPayload, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ParentHashOnNewPayload): string =
  var name = "parentHash==blockHash on NewPayload"
  if cs.syncing:
    name.add " (syncing)"
  return name

# Copy the parentHash into the blockHash, client should reject the payload
# (from Kintsugi Incident Report: https:#notes.ethereum.org/@ExXcnR0-SJGthjz1dwkA1A/BkkdHWXTY)
method execute(cs: ParentHashOnNewPayload, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  testCond env.clMock.produceBlocks(5, BlockProcessCallbacks())

  let pbRes = env.clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Alter hash on the payload and send it to client, should produce an error
      var payload = env.clMock.latestExecutableData
      if cs.syncing:
        # Parent hash is unknown but also (incorrectly) set as the block hash
        payload.parentHash = Web3Hash.randomBytes()

      payload.blockHash = payload.parentHash
      # Execution specification::
      # - (status: INVALID_BLOCK_HASH, latestValidHash: null, validationError: null) if the blockHash validation has failed
      # Starting from Shanghai, INVALID should be returned instead (https:#githucs.com/ethereum/execution-apis/pull/338)
      let
        version = env.engine.version(payload.timestamp)
        r = env.engine.client.newPayload(version, payload)

      if version >= Version.V2:
        r.expectStatus(PayloadExecutionStatus.invalid)
      else:
        r.expectStatusEither([PayloadExecutionStatus.invalid, PayloadExecutionStatus.invalidBlockHash])
      r.expectLatestValidHash()
      return true
  ))
  testCond pbRes
  return true
