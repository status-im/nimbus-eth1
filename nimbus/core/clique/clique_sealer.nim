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
## ===================!=============================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

{.push raises: [].}

import
  std/[sequtils, times],
  chronicles,
  chronos,
  eth/keys,
  "../.."/[constants, utils/ec_recover],
  ../../common/common,
  ./clique_cfg,
  ./clique_defs,
  ./clique_desc,
  ./clique_helpers,
  ./clique_snapshot,
  ./clique_verify,
  ./snapshot/[ballot, snapshot_desc]

logScope:
  topics = "clique PoA Mining"

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

proc isValidVote(s: Snapshot; a: EthAddress; authorize: bool): bool {.gcsafe, raises: [].} =
  s.ballot.isValidVote(a, authorize)

proc isSigner*(s: Snapshot; address: EthAddress): bool {.gcsafe, raises: [].} =
  ## See `clique_verify.isSigner()`
  s.ballot.isAuthSigner(address)

# clique/snapshot.go(319): func (s *Snapshot) inturn(number [..]
proc inTurn*(s: Snapshot; number: BlockNumber, signer: EthAddress): bool {.gcsafe, raises: [].} =
  ## See `clique_verify.inTurn()`
  let ascSignersList = s.ballot.authSigners
  for offset in 0 ..< ascSignersList.len:
    if ascSignersList[offset] == signer:
      return (number mod ascSignersList.len.u256) == offset.u256

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# clique/clique.go(681): func calcDifficulty(snap [..]
proc calcDifficulty(s: Snapshot; signer: EthAddress): DifficultyInt {.gcsafe, raises: [].} =
  if s.inTurn(s.blockNumber + 1, signer):
    DIFF_INTURN
  else:
    DIFF_NOTURN

proc recentBlockNumber*(s: Snapshot;
                        a: EthAddress): Result[BlockNumber,void] {.gcsafe, raises: [].} =
  ## Return `BlockNumber` for `address` argument (if any)
  for (number,recent) in s.recents.pairs:
    if recent == a:
      return ok(number)
  return err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# clique/clique.go(506): func (c *Clique) Prepare(chain [..]
proc prepare*(c: Clique; parent: BlockHeader, header: var BlockHeader): CliqueOkResult
                    {.gcsafe, raises: [CatchableError].} =
  ## For the Consensus Engine, `prepare()` initializes the consensus fields
  ## of a block header according to the rules of a particular engine.
  ##
  ## This implementation prepares all the consensus fields of the header for
  ## running the transactions on top.

  # Assemble the voting snapshot to check which votes make sense
  let rc = c.cliqueSnapshot(parent.blockHash, @[])
  if rc.isErr:
    return err(rc.error)

  # if we are not voting, coinbase should be filled with zero
  # because other subsystem e.g txpool can produce block header
  # with non zero coinbase. if that coinbase is one of the signer
  # and the nonce is zero, that signer will be vote out from
  # signer list
  header.coinbase.reset

  let modEpoch = (parent.blockNumber+1) mod c.cfg.epoch
  if modEpoch != 0:
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
  if modEpoch == 0:
    header.extraData.add c.snapshot.ballot.authSigners.mapIt(toSeq(it)).concat
  header.extraData.add 0.byte.repeat(EXTRA_SEAL)

  # Mix digest is reserved for now, set to empty
  header.mixDigest.reset

  # Ensure the timestamp has the correct delay
  header.timestamp = parent.timestamp + c.cfg.period
  if header.timestamp < getTime():
    header.timestamp = getTime()

  ok()

proc prepareForSeal*(c: Clique; prepHeader: BlockHeader; header: var BlockHeader) {.gcsafe, raises: [].} =
  # TODO: use system.move?
  header.nonce = prepHeader.nonce
  header.extraData = prepHeader.extraData
  header.mixDigest = prepHeader.mixDigest

# clique/clique.go(589): func (c *Clique) Authorize(signer [..]
proc authorize*(c: Clique; signer: EthAddress; signFn: CliqueSignerFn) {.gcsafe, raises: [].} =
  ## Injects private key into the consensus engine to mint new blocks with.
  c.signer = signer
  c.signFn = signFn

# clique/clique.go(724): func CliqueRLP(header [..]
proc cliqueRlp*(header: BlockHeader): seq[byte] {.gcsafe, raises: [].} =
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
proc sealHash*(header: BlockHeader): Hash256 {.gcsafe, raises: [].} =
  ## For the Consensus Engine, `sealHash()` returns the hash of a block prior
  ## to it being sealed.
  ##
  ## This implementation returns the hash of a block prior to it being sealed.
  header.hashSealHeader


# clique/clique.go(599): func (c *Clique) Seal(chain [..]
proc seal*(c: Clique; ethBlock: var EthBlock):
           Result[void,CliqueError] {.gcsafe,
            raises: [CatchableError].} =
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
  except CatchableError as exc:
    return err((errCliqueSealSigFn,
      "Error when signing block header: " & exc.msg))

  ethBlock = ethBlock.withHeader(header)
  ok()

# clique/clique.go(673): func (c *Clique) CalcDifficulty(chain [..]
proc calcDifficulty*(c: Clique;
                    parent: BlockHeader): Result[DifficultyInt,CliqueError]
                      {.gcsafe, raises: [CatchableError].} =
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
