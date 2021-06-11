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
  ./clique_utils,
  eth/common,
  sequtils,
  tables

type
  Vote* = object ## Vote represent single votes that an authorized
                 ## signer made to modify the list of authorizations.
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

  CliquePoll* = object
    votes: Table[EthAddress,Tally]  ## votes by account -> signer
    authSig: Table[EthAddress,bool] ## currently authorised signers
    authRemoved: bool               ## last `addVote()` action was removing an
                                    ## authorised signer from the `authSig` list

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc initCliquePoll*(t: var CliquePoll) =
  ## Ininialise an empty `CliquePoll` descriptor.
  t.votes = initTable[EthAddress,Tally]()
  t.authSig = initTable[EthAddress,bool]()

proc initCliquePoll*(t: var CliquePoll; signers: openArray[EthAddress]) =
  ## Ininialise `CliquePoll` with a given authorised signers list
  t.initCliquePoll
  for a in signers:
    t.authSig[a] = true

proc authSigners*(t: var CliquePoll): seq[EthAddress] =
  ## Sorted ascending list of authorised signer addresses
  toSeq(t.authSig.keys).sorted(EthAscending)

proc isAuthSigner*(t: var CliquePoll; address: EthAddress): bool =
  ## Check whether `address` is an authorised signer
  address in t.authSig

proc authSignersShrunk*(t: var CliquePoll): bool =
  ## Check whether the authorised signers list was shrunk recently after
  ## appying `addVote()`
  t.authRemoved

proc authSignersThreshold*(t: var CliquePoll): int =
  ## Returns the minimum number of authorised signers needed for authorising
  ## a addres for voting. This is currently
  ## ::
  ##   1 + half of the number of authorised signers
  ##
  1 + (t.authSig.len div 2)


proc delVote*(t: var CliquePoll; signer, address: EthAddress) =
  ## Remove a particular previously added vote.
  if address in t.votes:
    if signer in t.votes[address].signers:
      if t.votes[address].signers.len <= 1:
        t.votes.del(address)
      else:
        t.votes[address].signers.del(signer)


# clique/snapshot.go(141): func (s *Snapshot) validVote(address [..]
proc validVote*(t: var CliquePoll; address: EthAddress; authorize: bool): bool =
  ## Check whether voting would have an effect in `addVote()`
  if address in t.authSig: not authorize else: authorize


proc addVote*(t: var CliquePoll; vote: Vote) =
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

  echo ">>> addVote 1"

  # clique/snapshot.go(147): if !s.validVote(address, [..]
  if not t.validVote(vote.address, vote.authorize):
    # Voting has no effect
    return

  # clique/snapshot.go(253): if snap.cast(header.Coinbase, [..]
  echo ">>> addVote 2"

  # Collect vote
  var numVotes = 0
  if not t.votes.hasKey(vote.address):
    t.votes[vote.address] = Tally(
      authorize: vote.authorize,
      signers: {vote.signer: vote}.toTable)
    numVotes = 1
  elif t.votes[vote.address].authorize == vote.authorize:
    t.votes[vote.address].signers[vote.signer] = vote
    numVotes = t.votes[vote.address].signers.len
  else:
    return

  echo ">>> addVote 3"

  # clique/snapshot.go(262): if tally := snap.Tally[header.Coinbase]; [..]

  # Vote passed, update the list of authorised signers if enough votes
  if numVotes < t.authSignersThreshold:
    return

  echo ">>> addVote 4"

  var obsolete = @[vote.address]
  if vote.authorize:
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

  echo ">>> addVote done"

# ------------------------------------------------------------------------------
# Test interface
# ------------------------------------------------------------------------------

proc votesInternal*(t: var CliquePoll): seq[(EthAddress,EthAddress,Vote)] =
  for account in toSeq(t.votes.keys).sorted(EthAscending):
    let tally = t.votes[account]
    for signer in toSeq(tally.signers.keys).sorted(EthAscending):
      result.add (account, signer, tally.signers[signer])

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
