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
## Snapshot Processor for Clique PoA Consensus Protocol
## ====================================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[tables, times],
  ../clique_cfg,
  ../clique_defs,
  ./ballot,
  ./snapshot_desc,
  chronicles,
  eth/[common, rlp],
  stew/results

{.push raises: [Defect].}

logScope:
  topics = "clique PoA snapshot-apply"

# ------------------------------------------------------------------------------
# Private functions needed to support RLP conversion
# ------------------------------------------------------------------------------

proc say(s: var Snapshot; v: varargs[string,`$`]) {.inline.} =
  # s.cfg.say v
  discard

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# clique/snapshot.go(185): func (s *Snapshot) apply(headers [..]
proc snapshotApply*(s: var Snapshot;
                    headers: openArray[BlockHeader]): CliqueOkResult {.
                      gcsafe, raises: [Defect,CatchableError].} =
  ## Initialises an authorization snapshot `snap` by applying the `headers`
  ## to the argument snapshot desciptor `s`.

  #s.say "applySnapshot ", s.pp(headers).join("\n" & ' '.repeat(18))

  # Allow passing in no headers for cleaner code
  if headers.len == 0:
    return ok()

  # Sanity check that the headers can be applied
  if headers[0].blockNumber != s.blockNumber + 1:
    return err((errInvalidVotingChain,""))
  # clique/snapshot.go(191): for i := 0; i < len(headers)-1; i++ {
  for i in 0 ..< headers.len - 1:
    if headers[i+1].blockNumber != headers[i].blockNumber+1:
      return err((errInvalidVotingChain,""))

  # Iterate through the headers and create a new snapshot
  let
    start = getTime()
    logInterval = initDuration(seconds = 8)
  var
    logged = start

  s.say "applySnapshot state=", s.pp(25)

  # clique/snapshot.go(206): for i, header := range headers [..]
  for headersIndex in 0 ..< headers.len:
    let
      # headersIndex => also used for logging at the end of this loop
      header = headers[headersIndex]
      number = header.blockNumber

    s.say "applySnapshot processing #", number

    # Remove any votes on checkpoint blocks
    if (number mod s.cfg.epoch) == 0:
      # Note that the correctness of the authorised accounts list is verified in
      #   clique/clique.verifyCascadingFields(),
      #   see clique/clique.go(355): if number%c.config.Epoch == 0 {
      # This means, the account list passed with the epoch header is verified
      # to be the same as the one we already have.
      #
      # clique/snapshot.go(210): snap.Votes = nil
      s.ballot.flushVotes
      s.say "applySnapshot epoch => reset, state=", s.pp(41)

    # Delete the oldest signer from the recent list to allow it signing again
    block:
      let limit = s.ballot.authSignersThreshold.u256
      if limit <= number:
        s.recents.del(number - limit)

    # Resolve the authorization key and check against signers
    let signer = ? s.cfg.ecRecover(header)
    s.say "applySnapshot signer=", s.pp(signer)

    if not s.ballot.isAuthSigner(signer):
      s.say "applySnapshot signer not authorised => fail ", s.pp(29)
      return err((errUnauthorizedSigner,""))

    for recent in s.recents.values:
      if recent == signer:
        s.say "applySnapshot signer recently seen ", s.pp(signer)
        return err((errRecentlySigned,""))
    s.recents[number] = signer

    # Header authorized, discard any previous vote from the signer
    # clique/snapshot.go(233): for i, vote := range snap.Votes {
    s.ballot.delVote(signer = signer, address = header.coinbase)

    # Tally up the new vote from the signer
    # clique/snapshot.go(244): var authorize bool
    var authOk = false
    if header.nonce == NONCE_AUTH:
      authOk = true
    elif header.nonce != NONCE_DROP:
      return err((errInvalidVote,""))
    let vote = Vote(address:     header.coinbase,
                    signer:      signer,
                    blockNumber: number,
                    authorize:   authOk)
    s.say "applySnapshot calling addVote ", s.pp(vote)
    # clique/snapshot.go(253): if snap.cast(header.Coinbase, authorize) {
    s.ballot.addVote(vote)

    # clique/snapshot.go(269): if limit := uint64(len(snap.Signers)/2 [..]
    if s.ballot.isAuthSignersListShrunk:
      # Signer list shrunk, delete any leftover recent caches
      let limit = s.ballot.authSignersThreshold.u256
      if limit <= number:
        # Pop off least block number from the list
        let item = number - limit
        s.say "will delete recent item #", item, " (", number, "-", limit,
          ") from recents={", s.pp(s.recents), "}"
        s.recents.del(item)

    s.say "applySnapshot state=", s.pp(25)

    # If we're taking too much time (ecrecover), notify the user once a while
    if logInterval < logged - getTime():
      info "Reconstructing voting history",
        processed = headersIndex,
        total = headers.len,
        elapsed = start - getTime()
      logged = getTime()

  let sinceStart = start - getTime()
  if logInterval < sinceStart:
    info "Reconstructed voting history",
      processed = headers.len,
      elapsed = sinceStart

  # clique/snapshot.go(303): snap.Number += uint64(len(headers))
  s.blockNumber = s.blockNumber + headers.len.u256
  s.blockHash = headers[^1].blockHash
  result = ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
