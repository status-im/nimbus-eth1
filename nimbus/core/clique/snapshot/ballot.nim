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
## Votes Management for Clique PoA Consensus Protocol
## =================================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[sequtils, tables],
  ../clique_helpers,
  eth/common

type
  Vote* = object
    ## Vote represent single votes that an authorized signer made to modify
    ## the list of authorizations.
    signer*: EthAddress       ## authorized signer that cast this vote
    address*: EthAddress      ## account being voted on to change its
                              ## authorization type (`true` or `false`)
    blockNumber*: BlockNumber ## block number the vote was cast in
                              ## (expire old votes)
    authorize*: bool          ## authorization type,  whether to authorize or
                              ## deauthorize the voted account

  Tally = object
    authorize: bool
    signers: Table[EthAddress,Vote]

  Ballot* = object
    votes: Table[EthAddress,Tally]  ## votes by account -> signer
    authSig: Table[EthAddress,bool] ## currently authorised signers
    authRemoved: bool               ## last `addVote()` action was removing an
                                    ## authorised signer from the `authSig` list

{.push raises: [].}

# ------------------------------------------------------------------------------
# Public debugging/pretty-printer support
# ------------------------------------------------------------------------------

proc votesInternal*(t: var Ballot): seq[(EthAddress,EthAddress,Vote)] =
  for account,tally in t.votes.pairs:
    for signer,vote in tally.signers.pairs:
      result.add (account, signer, vote)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc initBallot*(t: var Ballot) =
  ## Ininialise an empty `Ballot` descriptor.
  t.votes = initTable[EthAddress,Tally]()
  t.authSig = initTable[EthAddress,bool]()

proc initBallot*(t: var Ballot; signers: openArray[EthAddress]) =
  ## Ininialise `Ballot` with a given authorised signers list
  t.initBallot
  for a in signers:
    t.authSig[a] = true

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc authSigners*(t: var Ballot): seq[EthAddress] =
  ## Sorted ascending list of authorised signer addresses
  toSeq(t.authSig.keys).sorted(EthAscending)

proc authSignersLen*(t: var Ballot): int =
  ## Returns the number of currently known authorised signers.
  t.authSig.len

proc isAuthSignersListShrunk*(t: var Ballot): bool =
  ## Check whether the authorised signers list was shrunk recently after
  ## appying `addVote()`
  t.authRemoved

proc authSignersThreshold*(t: var Ballot): int =
  ## Returns the minimum number of authorised signers needed for authorising
  ## a addres for voting. This is currently
  ## ::
  ##   1 + half of the number of authorised signers
  ##
  1 + (t.authSig.len div 2)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc isAuthSigner*(t: var Ballot; addresses: var seq[EthAddress]): bool =
  ## Check whether all `addresses` entries are authorised signers.
  ##
  ## Using this function should be preferable over `authSigners()` which has
  ## complexity `O(log n)` while this function runs with `O(n)`.
  for a in addresses:
    if a notin t.authSig:
      return false
  true

proc isAuthSigner*(t: var Ballot; address: EthAddress): bool =
  ## Check whether `address` is an authorised signer
  address in t.authSig

proc delVote*(t: var Ballot; signer, address: EthAddress) {.
              gcsafe, raises: [KeyError].} =
  ## Remove a particular previously added vote.
  if address in t.votes:
    if signer in t.votes[address].signers:
      if t.votes[address].signers.len <= 1:
        t.votes.del(address)
      else:
        t.votes[address].signers.del(signer)


proc flushVotes*(t: var Ballot) =
  ## Reset/flush pending votes, authorised signers remain the same.
  t.votes.clear


# clique/snapshot.go(141): func (s *Snapshot) validVote(address [..]
proc isValidVote*(t: var Ballot; address: EthAddress; authorize: bool): bool =
  ## Check whether voting would have an effect in `addVote()`
  if address in t.authSig: not authorize else: authorize


proc addVote*(t: var Ballot; vote: Vote) {.
              gcsafe, raises: [KeyError].} =
  ## Add a new vote collecting the signers for the particular voting address.
  ##
  ## Unless it is the first vote for this address, the authorisation type
  ## `true` or `false` of the vote must match the previous one. For the first
  ## vote, the authorisation type `true` is accepted if the address is not an
  ## authorised signer, and `false` if it is an authorised signer. Otherwise
  ## the vote is ignored.
  ##
  ## If the number of signers for the particular address are at least
  ## `authSignersThreshold()`, the status of this address will change as
  ## follows.
  ##  * If the authorisation type is `true`, the address is added
  ##    to the list of authorised signers.
  ##  * If the authorisation type is `false`, the address is removed
  ##    from the list of authorised signers.
  t.authRemoved = false
  var
    numVotes = 0
    authOk = vote.authorize

  # clique/snapshot.go(147): if !s.validVote(address, [..]
  if not t.isValidVote(vote.address, vote.authorize):

    # Corner case: touch votes for this account
    if t.votes.hasKey(vote.address):
      let refVote =  t.votes[vote.address]
      numVotes = refVote.signers.len
      authOk = refVote.authorize

  elif not t.votes.hasKey(vote.address):
    # Collect inital vote
    t.votes[vote.address] = Tally(
      authorize: vote.authorize,
      signers: {vote.signer: vote}.toTable)
    numVotes = 1

  elif t.votes[vote.address].authorize == vote.authorize:
    # Collect additional vote
    t.votes[vote.address].signers[vote.signer] = vote
    numVotes = t.votes[vote.address].signers.len

  else:
    return

  # clique/snapshot.go(262): if tally := snap.Tally[header.Coinbase]; [..]

  # Vote passed, update the list of authorised signers if enough votes
  if numVotes < t.authSignersThreshold:
    return

  var obsolete = @[vote.address]
  if authOk:
    # Has minimum votes, so add it
    t.authSig[vote.address] = true
  else:
    # clique/snapshot.go(266): delete(snap.Signers, [..]
    t.authSig.del(vote.address)
    t.authRemoved = true

    # Not a signer anymore => remove it everywhere
    for key,value in t.votes.mpairs:
      if vote.address in value.signers:
        if 1 < value.signers.len:
          value.signers.del(vote.address)
        else:
          obsolete.add key

  for key in obsolete:
    t.votes.del(key)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
