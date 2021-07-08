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
## Miscellaneous Snapshot Functions for Clique PoA Consensus Protocol
## ==================================================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[tables],
  ./ballot,
  ./snapshot_desc,
  chronicles,
  eth/[common, rlp],
  stew/results

{.push raises: [Defect].}

logScope:
  topics = "clique PoA snapshot-misc"

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc signersThreshold*(s: var Snapshot): int {.inline.} =
  ## Minimum number of authorised signers needed.
  s.ballot.authSignersThreshold

#proc signers*(s: var Snapshot): seq[EthAddress] {.inline.} =
#  ## Retrieves the sorted list of authorized signers
#  s.ballot.authSigners

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc isValidVote*(s: var Snapshot; address: EthAddress; authorize: bool): bool =
  ## Returns `true` if voting makes sense, at all.
  s.ballot.isValidVote(address, authorize)

proc recent*(s: var Snapshot; address: EthAddress): Result[BlockNumber,void] =
  ## Return `BlockNumber` for `address` argument (if any)
  for (number,recent) in s.recents.pairs:
    if recent == address:
      return ok(number)
  return err()

proc isSigner*(s: var Snapshot; address: EthAddress): bool =
  ## Checks whether argukment ``address` is in signers list
  s.ballot.isAuthSigner(address)

# clique/snapshot.go(319): func (s *Snapshot) inturn(number [..]
proc inTurn*(s: var Snapshot; number: BlockNumber, signer: EthAddress): bool =
  ## Returns `true` if a signer at a given block height is in-turn or not.
  let ascSignersList = s.ballot.authSigners
  for offset in 0 ..< ascSignersList.len:
    if ascSignersList[offset] == signer:
      return (number mod ascSignersList.len.u256) == offset.u256

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
