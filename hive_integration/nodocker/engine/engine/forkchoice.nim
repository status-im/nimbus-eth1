import
  std/strutils,
  ./engine_spec

type
  ForkchoiceStateField = enum
    HeadblockHash      = "Head"
    SafeblockHash      = "Safe"
    FinalizedblockHash = "Finalized"

type
  InconsistentForkchoiceTest* = ref object of EngineSpec
		field*: ForkchoiceStateField

method withMainFork(cs: InconsistentForkchoiceTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: InconsistentForkchoiceTest): string =
	return "Inconsistent %s in ForkchoiceState", cs.Field)
)

# Send an inconsistent ForkchoiceState with a known payload that belongs to a side chain as head, safe or finalized.
method execute(cs: InconsistentForkchoiceTest, env: TestEnv): bool =
	# Wait until TTD is reached by this client
	let ok = waitFor env.clMock.waitForTTD()
  testCond ok

	shadow.canon = make([]*ExecutableData, 0)
	shadow.alt = make([]*ExecutableData, 0)
	# Produce blocks before starting the test
	env.clMock.produceBlocks(3, BlockProcessCallbacks(
		onGetPayload: proc(): bool =
			# Generate and send an alternative side chain
			customData = CustomPayloadData()
			customData.ExtraData = &([]byte(0x01))
			if len(shadow.alt) > 0 (
				customData.parentHash = &shadow.alt[len(shadow.alt)-1].blockHash
			)
			alternativePayload, err = customData.CustomizePayload(env.clMock.latestPayloadBuilt)
			if err != nil (
				fatal "Unable to construct alternative payload: %v", t.TestName, err)
			)
			shadow.alt = append(shadow.alt, alternativePayload)
			latestCanonicalPayload = env.clMock.latestPayloadBuilt
			shadow.canon = append(shadow.canon, &latestCanonicalPayload)

			# Send the alternative payload
			r = env.engine.client.newPayload(alternativePayload)
			r.expectStatusEither(PayloadExecutionStatus.valid, test.Accepted)
		),
	))
	# Send the invalid ForkchoiceStates
	inconsistentFcU = ForkchoiceStateV1(
		headblockHash:      shadow.canon[len(shadow.alt)-1].blockHash,
		safeblockHash:      shadow.canon[len(shadow.alt)-2].blockHash,
		finalizedblockHash: shadow.canon[len(shadow.alt)-3].blockHash,
	)
	switch cs.Field (
	case HeadblockHash:
		inconsistentFcU.headblockHash = shadow.alt[len(shadow.alt)-1].blockHash
	case SafeblockHash:
		inconsistentFcU.safeblockHash = shadow.alt[len(shadow.canon)-2].blockHash
	case FinalizedblockHash:
		inconsistentFcU.finalizedblockHash = shadow.alt[len(shadow.canon)-3].blockHash
	)
	r = env.engine.client.forkchoiceUpdated(inconsistentFcU, nil, env.clMock.latestPayloadBuilt.timestamp)
	r.expectError()

	# Return to the canonical chain
	r = env.engine.client.forkchoiceUpdated(env.clMock.latestForkchoice, nil, env.clMock.latestPayloadBuilt.timestamp)
	r.expectPayloadStatus(PayloadExecutionStatus.valid)
)

type
  ForkchoiceUpdatedUnknownblockHashTest* = ref object of EngineSpec
		field: ForkchoiceStateField

method withMainFork(cs: ForkchoiceUpdatedUnknownblockHashTest, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ForkchoiceUpdatedUnknownblockHashTest): string =
	return "Unknown %sblockHash", cs.Field)
)

# Send an inconsistent ForkchoiceState with a known payload that belongs to a side chain as head, safe or finalized.
method execute(cs: ForkchoiceUpdatedUnknownblockHashTest, env: TestEnv): bool =
	# Wait until TTD is reached by this client
	let ok = waitFor env.clMock.waitForTTD()
  testCond ok

	# Produce blocks before starting the test
	env.clMock.produceBlocks(5, BlockProcessCallbacks())

	# Generate a random block hash
	randomblockHash = common.Hash256()
	randomBytes(randomblockHash[:])

	if cs.Field == HeadblockHash (

		forkchoiceStateUnknownHeadHash = ForkchoiceStateV1(
			headblockHash:      randomblockHash,
			safeblockHash:      env.clMock.latestForkchoice.safeblockHash,
			finalizedblockHash: env.clMock.latestForkchoice.finalizedblockHash,
		)

		t.Logf("INFO (%v) forkchoiceStateUnknownHeadHash: %v\n", t.TestName, forkchoiceStateUnknownHeadHash)

		# Execution specification::
		# - (payloadStatus: (status: SYNCING, latestValidHash: null, validationError: null), payloadId: null)
		#   if forkchoiceState.headblockHash references an unknown payload or a payload that can't be validated
		#   because requisite data for the validation is missing
		r = env.engine.client.forkchoiceUpdated(forkchoiceStateUnknownHeadHash, nil, env.clMock.latestExecutedPayload.timestamp)
		r.expectPayloadStatus(PayloadExecutionStatus.syncing)

		payloadAttributes = env.clMock.latestPayloadAttributes
		payloadAttributes.timestamp += 1

		# Test again using PayloadAttributes, should also return SYNCING and no PayloadID
		r = env.engine.client.forkchoiceUpdated(forkchoiceStateUnknownHeadHash,
			&payloadAttributes, env.clMock.latestExecutedPayload.timestamp)
		r.expectPayloadStatus(PayloadExecutionStatus.syncing)
		r.ExpectPayloadID(nil)
	else:
		env.clMock.produceSingleBlock(BlockProcessCallbacks(
			# Run test after a new payload has been broadcast
			onNewPayloadBroadcast: proc(): bool =

				forkchoiceStateRandomHash = ForkchoiceStateV1(
					headblockHash:      env.clMock.latestExecutedPayload.blockHash,
					safeblockHash:      env.clMock.latestForkchoice.safeblockHash,
					finalizedblockHash: env.clMock.latestForkchoice.finalizedblockHash,
				)

				if cs.Field == SafeblockHash (
					forkchoiceStateRandomHash.safeblockHash = randomblockHash
				elif cs.Field == FinalizedblockHash (
					forkchoiceStateRandomHash.finalizedblockHash = randomblockHash
				)

				r = env.engine.client.forkchoiceUpdated(forkchoiceStateRandomHash, nil, env.clMock.latestExecutedPayload.timestamp)
				r.expectError()

				payloadAttributes = env.clMock.latestPayloadAttributes
				payloadAttributes.Random = common.Hash256()
				payloadAttributes.SuggestedFeeRecipient = common.Address()

				# Test again using PayloadAttributes, should also return INVALID and no PayloadID
				r = env.engine.client.forkchoiceUpdated(forkchoiceStateRandomHash,
					&payloadAttributes, env.clMock.latestExecutedPayload.timestamp)
				r.expectError()

			),
		))
	)
)
