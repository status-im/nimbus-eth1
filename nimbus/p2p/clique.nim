# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## EIP-225 Clique PoA Consensus Protocol
## =====================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[random, sequtils, strformat, tables, times],
  ../constants,
  ../db/[db_chain, state_db],
  ../utils,
  ./clique/[clique_cfg, clique_defs, clique_utils, ec_recover, recent_snaps],
  ./gaslimit,
  chronicles,
  chronos,
  eth/[common, keys, rlp],
  nimcrypto

export
  clique_cfg,
  clique_defs

type
  CliqueSyncDefect* = object of Defect
    ## Defect raised with lock/unlock problem

  # clique/clique.go(142): type SignerFn func(signer [..]
  CliqueSignerFn* =        ## Hashes and signs the data to be signed by
                           ## a backing account
    proc(signer: EthAddress;
         message: openArray[byte]): Result[Hash256,cstring] {.gcsafe.}

  Proposals = Table[EthAddress,bool]

  # clique/clique.go(172): type Clique struct { [..]
  Clique* = object ## Clique is the proof-of-authority consensus engine
                   ## proposed to support the Ethereum testnet following
                   ## the Ropsten attacks.
    cfg: CliqueCfg         ## Consensus engine parameters to fine tune behaviour

    recents: RecentSnaps   ## Snapshots for recent block to speed up reorgs
    # signatures => see CliqueCfg

    proposals: Proposals   ## Current list of proposals we are pushing

    signer: EthAddress     ## Ethereum address of the signing key
    signFn: CliqueSignerFn ## Signer function to authorize hashes with
    lock: AsyncLock        ## Protects the signer fields

    stopSealReq: bool      ## Stop running `seal()` function
    stopVHeaderReq: bool   ## Stop running `verifyHeader()` function

    fakeDiff: bool         ## Testing only: skip difficulty verifications
    debug: bool            ## debug mode

{.push raises: [Defect].}

logScope:
  topics = "clique PoA"

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

template doExclusively(c: var Clique; action: untyped) =
  waitFor c.lock.acquire
  action
  c.lock.release

template syncExceptionWrap(action: untyped) =
  try:
    action
  except:
    raise (ref CliqueSyncDefect)(msg: getCurrentException().msg)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# clique/clique.go(145): func ecrecover(header [..]
proc ecrecover(c: var Clique;
               header: BlockHeader): Result[EthAddress,CliqueError] {.
                 gcsafe, raises: [Defect,CatchableError].} =
  ## ecrecover extracts the Ethereum account address from a signed header.
  c.cfg.signatures.getEcRecover(header)


# clique/clique.go(369): func (c *Clique) snapshot(chain [..]
proc snapshot(c: var Clique; blockNumber: BlockNumber; hash: Hash256;
              parents: openArray[Blockheader]): Result[Snapshot,CliqueError] {.
                gcsafe, raises: [Defect,CatchableError].} =
  ## snapshot retrieves the authorization snapshot at a given point in time.
  c.recents.getRecentSnaps:
    RecentArgs(blockHash:   hash,
               blockNumber: blockNumber,
               parents:     toSeq(parents))


# clique/clique.go(463): func (c *Clique) verifySeal(chain [..]
proc verifySeal(c: var Clique; header: BlockHeader;
                parents: openArray[BlockHeader]): CliqueResult {.
                  gcsafe, raises: [Defect,CatchableError].} =
  ## Check whether the signature contained in the header satisfies the
  ## consensus protocol requirements. The method accepts an optional list of
  ## parent headers that aren't yet part of the local blockchain to generate
  ## the snapshots from.

  # Verifying the genesis block is not supported
  if header.blockNumber.isZero:
    return err((errUnknownBlock,""))

  # Retrieve the snapshot needed to verify this header and cache it
  var snap = c.snapshot(header.blockNumber-1, header.parentHash, parents)
  if snap.isErr:
      return err(snap.error)

  # Resolve the authorization key and check against signers
  let signer = c.ecrecover(header)
  if signer.isErr:
      return err(signer.error)

  if not snap.value.isSigner(signer.value):
    return err((errUnauthorizedSigner,""))

  let seen = snap.value.recent(signer.value)
  if seen.isOk:
    # Signer is among recents, only fail if the current block does not
    # shift it out
    if header.blockNumber - snap.value.signersThreshold.u256 < seen.value:
      return err((errRecentlySigned,""))

  # Ensure that the difficulty corresponds to the turn-ness of the signer
  if not c.fakeDiff:
    if snap.value.inTurn(header.blockNumber, signer.value):
      if header.difficulty != DIFF_INTURN:
        return err((errWrongDifficulty,""))
    else:
      if header.difficulty != DIFF_NOTURN:
        return err((errWrongDifficulty,""))

  return ok()


# clique/clique.go(314): func (c *Clique) verifyCascadingFields(chain [..]
proc verifyCascadingFields(c: var Clique; header: BlockHeader;
                           parents: openArray[BlockHeader]): CliqueResult {.
                             gcsafe, raises: [Defect,CatchableError].} =
  ## Verify all the header fields that are not standalone, rather depend on a
  ## batch of previous headers. The caller may optionally pass in a batch of
  ## parents (ascending order) to avoid looking those up from the database.
  ## This is useful for concurrently verifying a batch of new headers.

  # The genesis block is the always valid dead-end
  if header.blockNumber.isZero:
    return err((errZeroBlockNumberRejected,""))

  # Ensure that the block's timestamp isn't too close to its parent
  var parent: BlockHeader
  if 0 < parents.len:
    parent = parents[^1]
  else:
    let rc = c.cfg.dbChain.getBlockHeaderResult(header.blockNumber-1)
    if rc.isErr:
      return err((errUnknownAncestor,""))
    parent = rc.value

  if parent.blockNumber != header.blockNumber-1 or
     parent.hash != header.parentHash:
    return err((errUnknownAncestor,""))

  if header.timestamp < parent.timestamp + c.cfg.period:
    return err((errInvalidTimestamp,""))

  # Verify that the gasUsed is <= gasLimit
  if header.gasLimit < header.gasUsed:
    return err((errCliqueExceedsGasLimit,
                &"invalid gasUsed: have {header.gasUsed}, " &
                &"gasLimit {header.gasLimit}"))

  let rc = c.cfg.dbChain.validateGasLimitOrBaseFee(header, parent)
  if rc.isErr:
    return err((errCliqueGasLimitOrBaseFee, rc.error))

  # Retrieve the snapshot needed to verify this header and cache it
  var snap = c.snapshot(header.blockNumber-1, header.parentHash, parents)
  if snap.isErr:
    return err(snap.error)

  # If the block is a checkpoint block, verify the signer list
  if (header.blockNumber mod c.cfg.epoch.u256) == 0:
    let
      signersList = snap.value.signers
      extraList = header.extraData.extraDataAddresses
    if signersList != extraList:
      return err((errMismatchingCheckpointSigners,""))

  # All basic checks passed, verify the seal and return
  return c.verifySeal(header, parents)


# clique/clique.go(246): func (c *Clique) verifyHeader(chain [..]
proc verifyHeader(c: var Clique; header: BlockHeader;
                  parents: openArray[BlockHeader]): CliqueResult {.
                    gcsafe, raises: [Defect,CatchableError].} =
  ## Check whether a header conforms to the consensus rules.The caller may
  ## optionally pass in a batch of parents (ascending order) to avoid looking
  ## those up from the database. This is useful for concurrently verifying
  ## a batch of new headers.
  if header.blockNumber.isZero:
    return err((errUnknownBlock,""))

  # Don't waste time checking blocks from the future
  if getTime() < header.timestamp:
    return err((errFutureBlock,""))

  # Checkpoint blocks need to enforce zero beneficiary
  let isCheckPoint = (header.blockNumber mod c.cfg.epoch.u256) == 0
  if isCheckPoint and not header.coinbase.isZero:
    return err((errInvalidCheckpointBeneficiary,""))

  # Nonces must be 0x00..0 or 0xff..f, zeroes enforced on checkpoints
  if header.nonce != NONCE_AUTH and header.nonce != NONCE_DROP:
    return err((errInvalidVote,""))
  if isCheckPoint and header.nonce != NONCE_DROP:
    return err((errInvalidCheckpointVote,""))

  # Check that the extra-data contains both the vanity and signature
  if header.extraData.len < EXTRA_VANITY:
    return err((errMissingVanity,""))
  if header.extraData.len < EXTRA_VANITY + EXTRA_SEAL:
    return err((errMissingSignature,""))

  # Ensure that the extra-data contains a signer list on checkpoint,
  # but none otherwise
  let signersBytes = header.extraData.len - EXTRA_VANITY - EXTRA_SEAL
  if not isCheckPoint and signersBytes != 0:
    return err((errExtraSigners,""))

  if isCheckPoint and  (signersBytes mod EthAddress.len) != 0:
    return err((errInvalidCheckpointSigners,""))

  # Ensure that the mix digest is zero as we do not have fork protection
  # currently
  if not header.mixDigest.isZero:
    return err((errInvalidMixDigest,""))

  # Ensure that the block does not contain any uncles which are meaningless
  # in PoA
  if header.ommersHash != EMPTY_UNCLE_HASH:
    return err((errInvalidUncleHash,""))

  # Ensure that the block's difficulty is meaningful (may not be correct at
  # this point)
  if not header.blockNumber.isZero:
    if header.difficulty.isZero or
        (header.difficulty != DIFF_INTURN and
         header.difficulty != DIFF_NOTURN):
      return err((errInvalidDifficulty,""))

  # verify that the gas limit is <= 2^63-1
  when header.gasLimit.typeof isnot int64:
    if int64.high < header.gasLimit:
      return err((errCliqueExceedsGasLimit,
                  &"invalid gasLimit: have {header.gasLimit}, must be int64"))

  # If all checks passed, validate any special fields for hard forks
  let rc = c.cfg.dbChain.config.verifyForkHashes(header)
  if rc.isErr:
    return err(rc.error)

  # All basic checks passed, verify cascading fields
  return c.verifyCascadingFields(header, parents)


# clique/clique.go(681): func calcDifficulty(snap [..]
proc calcDifficulty(snap: var Snapshot; signer: EthAddress): DifficultyInt =
  if snap.inTurn(snap.blockNumber + 1, signer):
    DIFF_INTURN
  else:
    DIFF_NOTURN

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# clique/clique.go(191): func New(config [..]
proc initClique*(c: var Clique; cfg: CliqueCfg) =
  ## Initialiser for Clique proof-of-authority consensus engine with the
  ## initial signers set to the ones provided by the user.
  c.cfg = cfg
  c.recents = initRecentSnaps(cfg)
  c.proposals = initTable[EthAddress,bool]()
  c.lock = newAsyncLock()

proc initClique*(cfg: CliqueCfg): Clique =
  result.initClique(cfg)


proc setDebug*(c: var Clique; debug: bool) =
  ## Set debugging mode on/off and set the `fakeDiff` flag `true`
  c.fakeDiff = true
  c.debug = debug
  c.recents.setDebug(debug)


# clique/clique.go(212): func (c *Clique) Author(header [..]
proc author*(c: var Clique;
             header: BlockHeader): Result[EthAddress,CliqueError] {.
               gcsafe, raises: [Defect,CatchableError].} =
  ## For the Consensus Engine, `author()` retrieves the Ethereum address of the
  ## account that minted the given block, which may be different from the
  ## header's coinbase if a consensus engine is based on signatures.
  ##
  ## This implementation returns the Ethereum address recovered from the
  ## signature in the header's extra-data section.
  c.ecrecover(header)


# clique/clique.go(217): func (c *Clique) VerifyHeader(chain [..]
proc verifyHeader*(c: var Clique; header: BlockHeader): CliqueResult {.
                   gcsafe, raises: [Defect,CatchableError].} =
  ## For the Consensus Engine, `verifyHeader()` checks whether a header
  ## conforms to the consensus rules of a given engine. Verifying the seal
  ## may be done optionally here, or explicitly via the `verifySeal()` method.
  ##
  ## This implementation checks whether a header conforms to the consensus
  ## rules.
  c.verifyHeader(header, @[])

# clique/clique.go(224): func (c *Clique) VerifyHeader(chain [..]
proc verifyHeaders*(c: var Clique; headers: openArray[BlockHeader]):
                                Future[seq[CliqueResult]] {.async,gcsafe.} =
  ## For the Consensus Engine, `verifyHeader()` s similar to VerifyHeader, but
  ## verifies a batch of headers concurrently. This method is accompanied
  ## by a `stopVerifyHeader()` method that can abort the operations.
  ##
  ## This implementation checks whether a header conforms to the consensus
  ## rules. It verifies a batch of headers. If running in the background,
  ## the process can be stopped by calling the `stopVerifyHeader()` function.
  syncExceptionWrap:
    c.doExclusively:
      c.stopVHeaderReq = false
    for n in 0 ..< headers.len:
      c.doExclusively:
        let isStopRequest = c.stopVHeaderReq
      if isStopRequest:
        result.add cliqueResultErr((errCliqueStopped,""))
        break
      result.add c.verifyHeader(headers[n], headers[0 ..< n])
    c.doExclusively:
      c.stopVHeaderReq = false

proc stopVerifyHeader*(c: var Clique): bool {.discardable.} =
  ## Activate the stop flag for running `verifyHeader()` function.
  ## Returns `true` if the stop flag could be activated.
  syncExceptionWrap:
    c.doExclusively:
      if not c.stopVHeaderReq:
        c.stopVHeaderReq = true
        result = true


# clique/clique.go(450): func (c *Clique) VerifyUncles(chain [..]
proc verifyUncles*(c: var Clique; ethBlock: EthBlock): CliqueResult =
  ## For the Consensus Engine, `verifyUncles()` verifies that the given
  ## block's uncles conform to the consensus rules of a given engine.
  ##
  ## This implementation always returns an error for existing uncles as this
  ## consensus mechanism doesn't permit uncles.
  if 0 < ethBlock.uncles.len:
    return err((errCliqueUnclesNotAllowed,""))
  result = ok()


# clique/clique.go(506): func (c *Clique) Prepare(chain [..]
proc prepare*(c: var Clique; header: var BlockHeader): CliqueResult {.
              gcsafe, raises: [Defect,CatchableError].} =
  ## For the Consensus Engine, `prepare()` initializes the consensus fields
  ## of a block header according to the rules of a particular engine. The
  ## changes are executed inline.
  ##
  ## This implementation prepares all the consensus fields of the header for
  ## running the transactions on top.

  # If the block isn't a checkpoint, cast a random vote (good enough for now)
  header.coinbase.reset
  header.nonce.reset

  # Assemble the voting snapshot to check which votes make sense
  var snap = c.snapshot(header.blockNumber-1, header.parentHash, @[])
  if snap.isErr:
    return err(snap.error)

  if (header.blockNumber mod c.cfg.epoch) != 0:
    c.doExclusively:
      # Gather all the proposals that make sense voting on
      var addresses: seq[EthAddress]
      for (address,authorize) in c.proposals.pairs:
        if snap.value.validVote(address, authorize):
          addresses.add address

      # If there's pending proposals, cast a vote on them
      if 0 < addresses.len:
        header.coinbase = addresses[c.cfg.prng.rand(addresses.len-1)]
        header.nonce = if header.coinbase in c.proposals: NONCE_AUTH
                       else: NONCE_DROP

  # Set the correct difficulty
  header.difficulty = snap.value.calcDifficulty(c.signer)

  # Ensure the extra data has all its components
  header.extraData.setLen(EXTRA_VANITY)
  if (header.blockNumber mod c.cfg.epoch) == 0:
    header.extraData.add snap.value.signers.mapIt(toSeq(it)).concat
  header.extraData.add 0.byte.repeat(EXTRA_SEAL)

  # Mix digest is reserved for now, set to empty
  header.mixDigest.reset

  # Ensure the timestamp has the correct delay
  let parent = c.cfg.dbChain.getBlockHeaderResult(header.blockNumber-1)
  if parent.isErr:
    return err((errUnknownAncestor,""))

  header.timestamp = parent.value.timestamp + c.cfg.period
  if header.timestamp < getTime():
    header.timestamp = getTime()

  return ok()


# clique/clique.go(571): func (c *Clique) Finalize(chain [..]
proc finalize*(c: var Clique; header: BlockHeader; db: AccountStateDB) =
  ## For the Consensus Engine, `finalize()` runs any post-transaction state
  ## modifications (e.g. block rewards) but does not assemble the block.
  ##
  ## Note: The block header and state database might be updated to reflect any
  ##       consensus rules that happen at finalization (e.g. block rewards).
  ##
  ## Not implemented here, raises `AssertionDefect`
  raiseAssert "Not implemented"
  #
  # ## This implementation ensures no uncles are set, nor block rewards given.
  # # No block rewards in PoA, so the state remains as is and uncles are dropped
  # let deleteEmptyObjectsOk = c.cfg.config.eip158block <= header.blockNumber
  # header.stateRoot = db.intermediateRoot(deleteEmptyObjectsOk)
  # header.ommersHash = EMPTY_UNCLE_HASH

# clique/clique.go(579): func (c *Clique) FinalizeAndAssemble(chain [..]
proc finalizeAndAssemble*(c: var Clique; header: BlockHeader;
                          db: AccountStateDB; txs: openArray[Transaction];
                          receipts: openArray[Receipt]):
                            Result[EthBlock,CliqueError] =
  ## For the Consensus Engine, `finalizeAndAssemble()` runs any
  ## post-transaction state modifications (e.g. block rewards) and assembles
  ## the final block.
  ##
  ## Note: The block header and state database might be updated to reflect any
  ## consensus rules that happen at finalization (e.g. block rewards).
  ##
  ## Not implemented here, raises `AssertionDefect`
  raiseAssert "Not implemented"
  # ## Ensuring no uncles are set, nor block rewards given, and returns the
  # ## final block.
  #
  #  # Finalize block
  #  c.finalize(header, state, txs, uncles)
  #
  #  # Assemble and return the final block for sealing
  #  return types.NewBlock(header, txs, nil, receipts,
  #                        trie.NewStackTrie(nil)), nil


# clique/clique.go(589): func (c *Clique) Authorize(signer [..]
proc authorize*(c: var Clique; signer: EthAddress; signFn: CliqueSignerFn) =
  ## Injects private key into the consensus engine to mint new blocks with.
  syncExceptionWrap:
    c.doExclusively:
      c.signer = signer
      c.signFn = signFn


# clique/clique.go(724): func CliqueRLP(header [..]
proc cliqueRlp*(header: BlockHeader): seq[byte] =
  ## Returns the rlp bytes which needs to be signed for the proof-of-authority
  ## sealing. The RLP to sign consists of the entire header apart from the 65
  ## byte signature contained at the end of the extra data.
  ##
  ## Note, the method requires the extra data to be at least 65 bytes,
  ## otherwise it panics. This is done to avoid accidentally using both forms
  ## (signature present or not), which could be abused to produce different
  ##hashes for the same header.
  header.encodeSealHeader


# clique/clique.go(688): func SealHash(header *types.Header) common.Hash {
proc sealHash*(header: BlockHeader): Hash256 =
  ## For the Consensus Engine, `sealHash()` returns the hash of a block prior
  ## to it being sealed.
  ##
  ## This implementation returns the hash of a block prior to it being sealed.
  header.hashSealHeader


# clique/clique.go(599): func (c *Clique) Seal(chain [..]
proc seal*(c: var Clique; ethBlock: EthBlock):
                     Future[Result[EthBlock,CliqueError]] {.async,gcsafe.} =
  ## For the Consensus Engine, `seal()` generates a new sealing request for
  ## the given input block and pushes the result into the given channel.
  ##
  ## Note, the method returns immediately and will send the result async. More
  ## than one result may also be returned depending on the consensus algorithm.
  ##
  ## This implementation attempts to create a sealed block using the local
  ## signing credentials. If running in the background, the process can be
  ## stopped by calling the `stopSeal()` function.
  c.doExclusively:
    c.stopSealReq = false
  var header = ethBlock.header

  # Sealing the genesis block is not supported
  if header.blockNumber.isZero:
    return err((errUnknownBlock,""))

  # For 0-period chains, refuse to seal empty blocks (no reward but would spin
  # sealing)
  if c.cfg.period.isZero and ethBlock.txs.len == 0:
    info $nilCliqueSealNoBlockYet
    return err((nilCliqueSealNoBlockYet,""))

  # Don't hold the signer fields for the entire sealing procedure
  c.doExclusively:
    let
      signer = c.signer
      signFn = c.signFn

  # Bail out if we're unauthorized to sign a block
  var snap = c.snapshot(header.blockNumber-1, header.parentHash, @[])
  if snap.isErr:
    return err(snap.error)
  if not snap.value.isSigner(signer):
    return err((errUnauthorizedSigner,""))

  # If we're amongst the recent signers, wait for the next block
  let seen = snap.value.recent(signer)
  if seen.isOk:
    # Signer is among recents, only wait if the current block does not
    # shift it out
    if header.blockNumber < seen.value + snap.value.signersThreshold.u256:
      info $nilCliqueSealSignedRecently
      return err((nilCliqueSealSignedRecently,""))

  # Sweet, the protocol permits us to sign the block, wait for our time
  var delay = header.timestamp - getTime()
  if header.difficulty == DIFF_NOTURN:
    # It's not our turn explicitly to sign, delay it a bit
    let wiggle = snap.value.signersThreshold.int64 * WIGGLE_TIME
    # Kludge for limited rand() argument range
    if wiggle.inSeconds < (int.high div 1000).int64:
      let rndWiggleMs = c.cfg.prng.rand(wiggle.inMilliSeconds.int)
      delay += initDuration(milliseconds = rndWiggleMs)
    else:
      let rndWiggleSec = c.cfg.prng.rand((wiggle.inSeconds and int.high).int)
      delay += initDuration(seconds = rndWiggleSec)

  trace "Out-of-turn signing requested",
    wiggle = $wiggle

  # Sign all the things!
  let sigHash = signFn(signer,header.cliqueRlp)
  if sigHash.isErr:
    return err((errCliqueSealSigFn,$sigHash.error))
  let extraLen = header.extraData.len
  if EXTRA_SEAL < extraLen:
    header.extraData.setLen(extraLen - EXTRA_SEAL)
  header.extraData.add sigHash.value.data

  # Wait until sealing is terminated or delay timeout.
  trace "Waiting for slot to sign and propagate",
    delay = $delay

  # FIXME: double check
  let timeOutTime = getTime() + delay
  while getTime() < timeOutTime:
    c.doExclusively:
      let isStopRequest = c.stopVHeaderReq
    if isStopRequest:
      warn "Sealing result is not read by miner",
        sealhash = sealHash(header)
      return err((errCliqueStopped,""))
    poll()

  c.doExclusively:
    c.stopSealReq = false
  return ok(ethBlock.withHeader(header))

proc stopSeal*(c: var Clique): bool {.discardable.} =
  ## Activate the stop flag for running `seal()` function.
  ## Returns `true` if the stop flag could be activated.
  syncExceptionWrap:
    c.doExclusively:
      if not c.stopSealReq:
        c.stopSealReq = true
        result =true


# clique/clique.go(673): func (c *Clique) CalcDifficulty(chain [..]
proc calcDifficulty(c: var Clique;
                    parent: BlockHeader): Result[DifficultyInt,CliqueError] {.
                      gcsafe, raises: [Defect,CatchableError].} =
  ## For the Consensus Engine, `calcDifficulty()` is the difficulty adjustment
  ## algorithm. It returns the difficulty that a new block should have.
  ##
  ## This implementation  returns the difficulty that a new block should have:
  ## * DIFF_NOTURN(2) if BLOCK_NUMBER % SIGNER_COUNT != SIGNER_INDEX
  ## * DIFF_INTURN(1) if BLOCK_NUMBER % SIGNER_COUNT == SIGNER_INDEX
  var snap = c.snapshot(parent.blockNumber, parent.blockHash, @[])
  if snap.isErr:
    return err(snap.error)
  return ok(snap.value.calcDifficulty(c.signer))


# # clique/clique.go(710): func (c *Clique) SealHash(header [..]
# proc sealHash(c: var Clique; header: BlockHeader): Hash256 =
#   ## SealHash returns the hash of a block prior to it being sealed.
#   header.encodeSigHeader.keccakHash

# ------------------------------------------------------------------------------
# Test interface
# ------------------------------------------------------------------------------

proc snapshotInternal*(c: var Clique; number: BlockNumber; hash: Hash256;
                       parent: openArray[Blockheader]): auto {.
                         gcsafe, raises: [Defect,CatchableError].} =
  c.snapshot(number, hash, parent)

proc cfgInternal*(c: var Clique): CliqueCfg =
  c.cfg

proc pp*(rc: var Result[Snapshot,CliqueError]; indent = 0): string =
  if rc.isOk:
    rc.value.pp(indent)
  else:
    "(error: " & rc.error.pp & ")"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
