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
## Verify Headers for Clique PoA Consensus Protocol
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
  std/[strformat, times, sequtils],
  ../../utils/utils,
  ../../common/common,
  ../gaslimit,
  ./clique_cfg,
  ./clique_defs,
  ./clique_desc,
  ./clique_helpers,
  ./clique_snapshot,
  ./snapshot/[ballot, snapshot_desc],
  chronicles,
  stew/results

{.push raises: [].}

logScope:
  topics = "clique PoA verify header"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# consensus/misc/forks.go(30): func VerifyForkHashes(config [..]
proc verifyForkHashes(com: CommonRef; header: BlockHeader): CliqueOkResult
                        {.gcsafe, raises: [ValueError].} =
  ## Verify that blocks conforming to network hard-forks do have the correct
  ## hashes, to avoid clients going off on different chains.

  if com.eip150Block.isSome and
     com.eip150Block.get == header.blockNumber:

    # If the homestead reprice hash is set, validate it
    let
      eip150 = com.eip150Hash
      hash = header.blockHash

    if eip150 != hash:
      return err((errCliqueGasRepriceFork,
        &"Homestead gas reprice fork: have {eip150}, want {hash}"))

  return ok()

proc signersThreshold*(s: Snapshot): int =
  ## Minimum number of authorised signers needed.
  s.ballot.authSignersThreshold


proc recentBlockNumber*(s: Snapshot; a: EthAddress): Result[BlockNumber,void] =
  ## Return `BlockNumber` for `address` argument (if any)
  for (number,recent) in s.recents.pairs:
    if recent == a:
      return ok(number)
  return err()


proc isSigner*(s: Snapshot; address: EthAddress): bool =
  ## Checks whether argukment ``address` is in signers list
  s.ballot.isAuthSigner(address)


# clique/snapshot.go(319): func (s *Snapshot) inturn(number [..]
proc inTurn*(s: Snapshot; number: BlockNumber, signer: EthAddress): bool =
  ## Returns `true` if a signer at a given block height is in-turn.
  let ascSignersList = s.ballot.authSigners
  if 0 < ascSignersList.len:
    let offset = (number mod ascSignersList.len.u256).truncate(int64)
    return ascSignersList[offset] == signer

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# clique/clique.go(463): func (c *Clique) verifySeal(chain [..]
proc verifySeal(c: Clique; header: BlockHeader): CliqueOkResult =
  ## Check whether the signature contained in the header satisfies the
  ## consensus protocol requirements. The method accepts an optional list of
  ## parent headers that aren't yet part of the local blockchain to generate
  ## the snapshots from.

  # Verifying the genesis block is not supported
  if header.blockNumber.isZero:
    return err((errUnknownBlock,""))

  # Get current snapshot
  let snapshot = c.snapshot

  # Verify availability of the cached snapshot
  doAssert snapshot.blockHash == header.parentHash

  # Resolve the authorization key and check against signers
  let signer = c.cfg.ecRecover(header)
  if signer.isErr:
    return err((errEcRecover,$signer.error))

  if not snapshot.isSigner(signer.value):
    return err((errUnauthorizedSigner,""))

  let seen = snapshot.recentBlockNumber(signer.value)
  if seen.isOk:
    # Signer is among recents, only fail if the current block does not
    # shift it out
    # clique/clique.go(486): if limit := uint64(len(snap.Signers)/2 + 1); [..]
    if header.blockNumber - snapshot.signersThreshold.u256 < seen.value:
      return err((errRecentlySigned,""))

  # Ensure that the difficulty corresponds to the turn-ness of the signer
  if snapshot.inTurn(header.blockNumber, signer.value):
    if header.difficulty != DIFF_INTURN:
      return err((errWrongDifficulty,"INTURN expected"))
  else:
    if header.difficulty != DIFF_NOTURN:
      return err((errWrongDifficulty,"NOTURN expected"))

  ok()


# clique/clique.go(314): func (c *Clique) verifyCascadingFields(chain [..]
proc verifyCascadingFields(c: Clique; com: CommonRef; header: BlockHeader;
                           parents: var seq[BlockHeader]): CliqueOkResult
                                {.gcsafe, raises: [CatchableError].} =
  ## Verify all the header fields that are not standalone, rather depend on a
  ## batch of previous headers. The caller may optionally pass in a batch of
  ## parents (ascending order) to avoid looking those up from the database.
  ## This is useful for concurrently verifying a batch of new headers.

  # The genesis block is the always valid dead-end
  if header.blockNumber.isZero:
    return ok()

  # Ensure that the block's timestamp isn't too close to its parent
  var parent: BlockHeader
  if 0 < parents.len:
    parent = parents[^1]
  elif not c.db.getBlockHeader(header.blockNumber-1, parent):
    return err((errUnknownAncestor,""))

  if parent.blockNumber != header.blockNumber-1 or
     parent.blockHash != header.parentHash:
    return err((errUnknownAncestor,""))

  # clique/clique.go(330): if parent.Time+c.config.Period > header.Time {
  if header.timestamp < parent.timestamp + c.cfg.period:
    return err((errInvalidTimestamp,""))

  # Verify that the gasUsed is <= gasLimit
  block:
    # clique/clique.go(333): if header.GasUsed > header.GasLimit {
    let (used, limit) = (header.gasUsed, header.gasLimit)
    if limit < used:
      return err((errCliqueExceedsGasLimit,
                  &"invalid gasUsed: have {used}, gasLimit {limit}"))

  # Verify `GasLimit` or `BaseFee` depending on whether before or after
  # EIP-1559/London fork.
  block:
    # clique/clique.go(337): if !chain.Config().IsLondon(header.Number) {
    let rc = com.validateGasLimitOrBaseFee(header, parent)
    if rc.isErr:
      return err((errCliqueGasLimitOrBaseFee, rc.error))

  # Retrieve the snapshot needed to verify this header and cache it
  block:
    # clique/clique.go(350): snap, err := c.snapshot(chain, number-1, ..
    let rc = c.cliqueSnapshotSeq(header.parentHash, parents)
    if rc.isErr:
      return err(rc.error)

  # If the block is a checkpoint block, verify the signer list
  if (header.blockNumber mod c.cfg.epoch.u256) == 0:
    var addrList = header.extraData.extraDataAddresses
    # not using `authSigners()` here as it is too slow
    if c.snapshot.ballot.authSignersLen != addrList.len or
       not c.snapshot.ballot.isAuthSigner(addrList):
      return err((errMismatchingCheckpointSigners,""))

  # All basic checks passed, verify the seal and return
  return c.verifySeal(header)


proc verifyHeaderFields(c: Clique; header: BlockHeader): CliqueOkResult =
  ## Check header fields, the ones that do not depend on a parent block.
  # clique/clique.go(250): number := header.Number.Uint64()

  # Don't waste time checking blocks from the future
  if EthTime.now() < header.timestamp:
    return err((errFutureBlock,""))

  # Checkpoint blocks need to enforce zero beneficiary
  let isCheckPoint = (header.blockNumber mod c.cfg.epoch.u256).isZero
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

  # Ensure that the extra-data contains a signer list on a checkpoint,
  # but none otherwise
  let signersBytes = header.extraData.len - EXTRA_VANITY - EXTRA_SEAL
  if not isCheckPoint:
    if signersBytes != 0:
      return err((errExtraSigners,""))
  elif (signersBytes mod EthAddress.len) != 0:
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
    # Note that neither INTURN or NOTURN should be zero (but this might be
    # subject to change as it is explicitely checked for in `clique.go`)
    let diffy = header.difficulty
    # clique/clique.go(246): if header.Difficulty == nil || (header.Difficulty..
    if diffy.isZero or (diffy != DIFF_INTURN and diffy != DIFF_NOTURN):
      return err((errInvalidDifficulty,""))

  # verify that the gas limit is <= 2^63-1
  when header.gasLimit.typeof isnot int64:
    if int64.high < header.gasLimit:
      return err((errCliqueExceedsGasLimit,
                  &"invalid gasLimit: have {header.gasLimit}, must be int64"))
  ok()


# clique/clique.go(246): func (c *Clique) verifyHeader(chain [..]
proc cliqueVerifyImpl(c: Clique; com: CommonRef; header: BlockHeader;
                      parents: var seq[BlockHeader]): CliqueOkResult
                  {.gcsafe, raises: [CatchableError].} =
  ## Check whether a header conforms to the consensus rules. The caller may
  ## optionally pass in a batch of parents (ascending order) to avoid looking
  ## those up from the database. This is useful for concurrently verifying
  ## a batch of new headers.
  c.failed = (ZERO_HASH256,cliqueNoError)

  block:
    # Check header fields independent of parent blocks
    let rc = c.verifyHeaderFields(header)
    if rc.isErr:
      c.failed = (header.blockHash, rc.error)
      return err(rc.error)

  block:
    # If all checks passed, validate any special fields for hard forks
    let rc = com.verifyForkHashes(header)
    if rc.isErr:
      c.failed = (header.blockHash, rc.error)
      return err(rc.error)

  # All basic checks passed, verify cascading fields
  result = c.verifyCascadingFields(com, header, parents)
  if result.isErr:
    c.failed = (header.blockHash, result.error)

proc cliqueVerifySeq*(c: Clique; com: CommonRef; header: BlockHeader;
                      parents: var seq[BlockHeader]): CliqueOkResult
                  {.gcsafe, raises: [CatchableError].} =
  ## Check whether a header conforms to the consensus rules. The caller may
  ## optionally pass in a batch of parents (ascending order) to avoid looking
  ## those up from the database. This is useful for concurrently verifying
  ## a batch of new headers.
  ##
  ## On success, the latest authorised signers list is available via the
  ## fucntion `c.cliqueSigners()`. Otherwise, the latest error is also stored
  ## in the `Clique` descriptor
  ##
  ## If there is an error, this error is also stored within the `Clique`
  ## descriptor and can be retrieved via `c.failed` along with the hash/ID of
  ## the failed block header.
  block:
    let rc = c.cliqueVerifyImpl(com, header, parents)
    if rc.isErr:
      return rc

  # Adjust current shapshot (the function `cliqueVerifyImpl()` typically
  # works with the parent snapshot.
  block:
    let rc = c.cliqueSnapshotSeq(header, parents)
    if rc.isErr:
      return err(rc.error)

  ok()

proc cliqueVerifySeq(c: Clique; com: CommonRef;
                 headers: var seq[BlockHeader]): CliqueOkResult
                 {.gcsafe, raises: [CatchableError].} =
  ## This function verifies a batch of headers checking each header for
  ## consensus rules conformance. The `headers` list is supposed to
  ## contain a chain of headers, i e. `headers[i]` is parent to `headers[i+1]`.
  ##
  ## On success, the latest authorised signers list is available via the
  ## fucntion `c.cliqueSigners()`. Otherwise, the latest error is also stored
  ## in the `Clique` descriptor
  ##
  ## If there is an error, this error is also stored within the `Clique`
  ## descriptor and can be retrieved via `c.failed` along with the hash/ID of
  ## the failed block header.
  ##
  ## Note that the sequence argument must be write-accessible, even though it
  ## will be left untouched by this function.
  if 0 < headers.len:
    headers.shallow

    block:
      var blind: seq[BlockHeader]
      let rc = c.cliqueVerifyImpl(com, headers[0],blind)
      if rc.isErr:
        return rc

    for n in 1 ..< headers.len:
      var parent = headers[n-1 .. n-1] # is actually a single item squence
      let rc = c.cliqueVerifyImpl(com, headers[n],parent)
      if rc.isErr:
        return rc

    # Adjust current shapshot (the function `cliqueVerifyImpl()` typically
    # works with the parent snapshot.
    block:
      let rc = c.cliqueSnapshot(headers[^1])
      if rc.isErr:
        return err(rc.error)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc cliqueVerify*(c: Clique; com: CommonRef; header: BlockHeader;
                  parents: openArray[BlockHeader]): CliqueOkResult
                        {.gcsafe, raises: [CatchableError].} =
  ## Check whether a header conforms to the consensus rules. The caller may
  ## optionally pass on a batch of parents (ascending order) to avoid looking
  ## those up from the database. This function updates the list of authorised
  ## signers (see `cliqueSigners()` below.)
  ##
  ## On success, the latest authorised signers list is available via the
  ## fucntion `c.cliqueSigners()`. Otherwise, the latest error is also stored
  ## in the `Clique` descriptor and is accessible as `c.failed`.
  ##
  ## This function is not transaction-save, that is the internal state of
  ## the authorised signers list has the state of the last update after a
  ## successful header verification. The hash of the failing header together
  ## with the error message is then accessible as `c.failed`.
  ##
  ## Use the directives `cliqueSave()`, `cliqueDispose()`, and/or
  ## `cliqueRestore()` for transaction.
  var list = toSeq(parents)
  c.cliqueVerifySeq(com, header, list)

# clique/clique.go(217): func (c *Clique) VerifyHeader(chain [..]
proc cliqueVerify*(c: Clique; com: CommonRef; header: BlockHeader): CliqueOkResult
                        {.gcsafe, raises: [CatchableError].} =
  ## Consensus rules verifier without optional parents list.
  var blind: seq[BlockHeader]
  c.cliqueVerifySeq(com, header, blind)

proc cliqueVerify*(c: Clique; com: CommonRef;
                   headers: openArray[BlockHeader]): CliqueOkResult
                        {.gcsafe, raises: [CatchableError].} =
  ## This function verifies a batch of headers checking each header for
  ## consensus rules conformance (see also the other `cliqueVerify()` function
  ## instance.) The `headers` list is supposed to contain a chain of headers,
  ## i.e. `headers[i]` is parent to `headers[i+1]`.
  ##
  ## On success, the latest authorised signers list is available via the
  ## fucntion `c.cliqueSigners()`. Otherwise, the latest error is also stored
  ## in the `Clique` descriptor and is accessible as `c.failed`.
  ##
  ## This function is not transaction-save, that is the internal state of
  ## the authorised signers list has the state of the last update after a
  ## successful header verification. The hash of the failing header together
  ## with the error message is then accessible as `c.failed`.
  ##
  ## Use the directives `cliqueSave()`, `cliqueDispose()`, and/or
  ## `cliqueRestore()` for transaction.
  var list = toSeq(headers)
  c.cliqueVerifySeq(com, list)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
