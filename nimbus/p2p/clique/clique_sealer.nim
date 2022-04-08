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
## Mining Support for Clique PoA Consensus Protocol
## ================================================
##
## Note that mining in currently unsupported by `NIMBUS`
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[sequtils, tables, times],
  ../../constants,
  ../../utils/ec_recover,
  ./clique_cfg,
  ./clique_defs,
  ./clique_desc,
  ./clique_helpers,
  ./clique_snapshot,
  ./clique_verify,
  ./snapshot/[ballot, snapshot_desc],
  chronicles,
  chronos,
  eth/[common, keys, rlp]

{.push raises: [Defect].}

logScope:
  topics = "clique PoA Mining"

type
  CliqueSyncDefect* = object of Defect
    ## Defect raised with lock/unlock problem

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

template syncExceptionWrap(action: untyped) =
  try:
    action
  except:
    raise (ref CliqueSyncDefect)(msg: getCurrentException().msg)


# clique/clique.go(217): func (c *Clique) VerifyHeader(chain [..]
proc verifyHeader(c: Clique; header: BlockHeader): CliqueOkResult
                  {.gcsafe, raises: [Defect,CatchableError].} =
  ## See `clique.cliqueVerify()`
  var blind: seq[BlockHeader]
  c.cliqueVerifySeq(header, blind)

proc verifyHeader(c: Clique; header: BlockHeader;
                  parents: openArray[BlockHeader]): CliqueOkResult
                        {.gcsafe, raises: [Defect,CatchableError].} =
  ## See `clique.cliqueVerify()`
  var list = toSeq(parents)
  c.cliqueVerifySeq(header, list)


proc isValidVote(s: Snapshot; a: EthAddress; authorize: bool): bool  {.inline.}=
  s.ballot.isValidVote(a, authorize)

proc isSigner*(s: Snapshot; address: EthAddress): bool =
  ## See `clique_verify.isSigner()`
  s.ballot.isAuthSigner(address)

# clique/snapshot.go(319): func (s *Snapshot) inturn(number [..]
proc inTurn*(s: Snapshot; number: BlockNumber, signer: EthAddress): bool =
  ## See `clique_verify.inTurn()`
  let ascSignersList = s.ballot.authSigners
  for offset in 0 ..< ascSignersList.len:
    if ascSignersList[offset] == signer:
      return (number mod ascSignersList.len.u256) == offset.u256

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# clique/clique.go(681): func calcDifficulty(snap [..]
proc calcDifficulty(s: Snapshot; signer: EthAddress): DifficultyInt =
  if s.inTurn(s.blockNumber + 1, signer):
    DIFF_INTURN
  else:
    DIFF_NOTURN

proc recentBlockNumber*(s: Snapshot;
                        a: EthAddress): Result[BlockNumber,void] {.inline.} =
  ## Return `BlockNumber` for `address` argument (if any)
  for (number,recent) in s.recents.pairs:
    if recent == a:
      return ok(number)
  return err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# clique/clique.go(212): func (c *Clique) Author(header [..]
proc author*(c: Clique; header: BlockHeader): Result[EthAddress,UtilsError]
                  {.gcsafe, raises: [Defect,CatchableError].} =
  ## For the Consensus Engine, `author()` retrieves the Ethereum address of the
  ## account that minted the given block, which may be different from the
  ## header's coinbase if a consensus engine is based on signatures.
  ##
  ## This implementation returns the Ethereum address recovered from the
  ## signature in the header's extra-data section.
  c.cfg.ecRecover(header)


# clique/clique.go(224): func (c *Clique) VerifyHeader(chain [..]
proc verifyHeaders*(c: Clique; headers: openArray[BlockHeader]):
                                Future[seq[CliqueOkResult]] {.async,gcsafe.} =
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

proc stopVerifyHeader*(c: Clique): bool {.discardable.} =
  ## Activate the stop flag for running `verifyHeader()` function.
  ## Returns `true` if the stop flag could be activated.
  syncExceptionWrap:
    c.doExclusively:
      if not c.stopVHeaderReq:
        c.stopVHeaderReq = true
        result = true


# clique/clique.go(450): func (c *Clique) VerifyUncles(chain [..]
proc verifyUncles*(c: Clique; ethBlock: EthBlock): CliqueOkResult =
  ## For the Consensus Engine, `verifyUncles()` verifies that the given
  ## block's uncles conform to the consensus rules of a given engine.
  ##
  ## This implementation always returns an error for existing uncles as this
  ## consensus mechanism doesn't permit uncles.
  if 0 < ethBlock.uncles.len:
    return err((errCliqueUnclesNotAllowed,""))
  result = ok()


# clique/clique.go(506): func (c *Clique) Prepare(chain [..]
proc prepare*(c: Clique; parent: BlockHeader, header: var BlockHeader): CliqueOkResult
                    {.gcsafe, raises: [Defect, CatchableError].} =
  ## For the Consensus Engine, `prepare()` initializes the consensus fields
  ## of a block header according to the rules of a particular engine. The
  ## changes are executed inline.
  ##
  ## This implementation prepares all the consensus fields of the header for
  ## running the transactions on top.

  # Assemble the voting snapshot to check which votes make sense
  let rc = c.cliqueSnapshot(header.parentHash, @[])
  if rc.isErr:
    return err(rc.error)

  if (header.blockNumber mod c.cfg.epoch) != 0:
    c.doExclusively:
      # Gather all the proposals that make sense voting on
      var addresses: seq[EthAddress]
      for (address,authorize) in c.proposals.pairs:
        if c.snapshot.isValidVote(address, authorize):
          addresses.add address

      # If there's pending proposals, cast a vote on them
      if 0 < addresses.len:
        header.coinbase = addresses[c.cfg.rand(addresses.len-1)]
        header.nonce = if header.coinbase in c.proposals: NONCE_AUTH
                       else: NONCE_DROP

  # Set the correct difficulty
  header.difficulty = c.snapshot.calcDifficulty(c.signer)

  # Ensure the extra data has all its components
  header.extraData.setLen(EXTRA_VANITY)
  if (header.blockNumber mod c.cfg.epoch) == 0:
    header.extraData.add c.snapshot.ballot.authSigners.mapIt(toSeq(it)).concat
  header.extraData.add 0.byte.repeat(EXTRA_SEAL)

  # Mix digest is reserved for now, set to empty
  header.mixDigest.reset

  # Ensure the timestamp has the correct delay
  header.timestamp = parent.timestamp + c.cfg.period
  if header.timestamp < getTime():
    header.timestamp = getTime()

  ok()

# clique/clique.go(589): func (c *Clique) Authorize(signer [..]
proc authorize*(c: Clique; signer: EthAddress; signFn: CliqueSignerFn) =
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
proc seal*(c: Clique; ethBlock: var EthBlock):
           Result[void,CliqueError] {.gcsafe,
            raises: [Defect,CatchableError].} =
  ## This implementation attempts to create a sealed block using the local
  ## signing credentials.

  var header = ethBlock.header

  # Sealing the genesis block is not supported
  if header.blockNumber.isZero:
    return err((errUnknownBlock, ""))

  # For 0-period chains, refuse to seal empty blocks (no reward but would spin
  # sealing)
  if c.cfg.period.isZero and ethBlock.txs.len == 0:
    info $nilCliqueSealNoBlockYet
    return err((nilCliqueSealNoBlockYet, ""))

  # Don't hold the signer fields for the entire sealing procedure
  c.doExclusively:
    let
      signer = c.signer
      signFn = c.signFn

  # Bail out if we're unauthorized to sign a block
  let rc = c.cliqueSnapshot(header.parentHash)
  if rc.isErr:
    return err(rc.error)
  if not c.snapshot.isSigner(signer):
    return err((errUnauthorizedSigner, ""))

  # If we're amongst the recent signers, wait for the next block
  let seen = c.snapshot.recentBlockNumber(signer)
  if seen.isOk:
    # Signer is among recents, only wait if the current block does not
    # shift it out
    if header.blockNumber < seen.value + c.snapshot.signersThreshold.u256:
      info $nilCliqueSealSignedRecently
      return err((nilCliqueSealSignedRecently, ""))

  # Sweet, the protocol permits us to sign the block, wait for our time
  var delay = header.timestamp - getTime()
  if header.difficulty == DIFF_NOTURN:
    # It's not our turn explicitly to sign, delay it a bit
    let wiggle = c.snapshot.signersThreshold.int64 * WIGGLE_TIME
    # Kludge for limited rand() argument range
    if wiggle.inSeconds < (int.high div 1000).int64:
      let rndWiggleMs = c.cfg.rand(wiggle.inMilliseconds.int)
      delay += initDuration(milliseconds = rndWiggleMs)
    else:
      let rndWiggleSec = c.cfg.rand((wiggle.inSeconds and int.high).int)
      delay += initDuration(seconds = rndWiggleSec)

    trace "Out-of-turn signing requested",
      wiggle = $wiggle

  # Sign all the things!
  try:
    let signature = signFn(signer,header.cliqueRlp)
    if signature.isErr:
      return err((errCliqueSealSigFn,$signature.error))
    let extraLen = header.extraData.len
    if EXTRA_SEAL < extraLen:
      header.extraData.setLen(extraLen - EXTRA_SEAL)
    header.extraData.add signature.value
  except Exception as exc:
    return err((errCliqueSealSigFn, "Error when signing block header"))

  ethBlock = ethBlock.withHeader(header)
  ok()

# clique/clique.go(673): func (c *Clique) CalcDifficulty(chain [..]
proc calcDifficulty(c: Clique;
                    parent: BlockHeader): Result[DifficultyInt,CliqueError]
                      {.gcsafe, raises: [Defect,CatchableError].} =
  ## For the Consensus Engine, `calcDifficulty()` is the difficulty adjustment
  ## algorithm. It returns the difficulty that a new block should have.
  ##
  ## This implementation  returns the difficulty that a new block should have:
  ## * DIFF_NOTURN(2) if BLOCK_NUMBER % SIGNER_COUNT != SIGNER_INDEX
  ## * DIFF_INTURN(1) if BLOCK_NUMBER % SIGNER_COUNT == SIGNER_INDEX
  let rc = c.cliqueSnapshot(parent)
  if rc.isErr:
    return err(rc.error)
  return ok(c.snapshot.calcDifficulty(c.signer))


# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
