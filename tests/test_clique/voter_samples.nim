# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Test cases from https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md

import
  ../../nimbus/core/clique/clique_defs

type
  TesterVote* = object  ## VoterBlock represents a single block signed by a
                        ## particular account, where the account may or may not
                        ## have cast a Clique vote.
    signer*: string ##\
      ## Account that signed this particular block

    voted*: string ##\
      ## Optional value if the signer voted on adding/removing ## someone

    auth*: bool ##\
      ## Whether the vote was to authorize (or deauthorize)

    checkpoint*: seq[string] ##\
      ## List of authorized signers if this is an epoch block

    noTurn*: bool  ##\
      ## Initialise `NOTURN` if `true`, otherwise use `INTURN`. This is not
      ## part of Go ref test implementation. The flag used here to avoid what
      ## is implemented as `fakeDiff` kludge in the Go ref test implementation.
      ##
      ## Note that the `noTurn` value depends on the sort order of the
      ## calculated authorised signers account address list. These account
      ## addresses in turn (no pun intended) depend on the private keys of
      ## these accounts. Now, the private keys are generated on-the-fly by a
      ## PRNG which re-seeded the same for each test. So the sort order is
      ## predictable and the correct value of the the `noTurn` flag can be set
      ## by sort of experimenting with the tests (and/or refering to earlier
      ## woking test specs.)

    newbatch*: bool


  TestSpecs* = object   ## Defining genesis and the various voting scenarios
                        ## to test (see `votes`.)
    id*: int ##\
      ## Test id

    info*: string ##\
      ## Test description

    epoch*: int ##\
      ## Number of blocks in an epoch (unset = 30000)

    runBack*: bool ##\
      ## Set `applySnapsMinBacklog` flag

    signers*: seq[string] ##\
      ## Initial list of authorized signers in the genesis

    votes*: seq[TesterVote] ##\
      ## Chain of signed blocks, potentially influencing auths

    results*: seq[string] ##\
      ## Final list of authorized signers after all blocks

    failure*: CliqueErrorType ##\
      ## Failure if some block is invalid according to the rules

const
  # Define the various voting scenarios to test
  voterSamples* = [
    # clique/snapshot_test.go(108): {
    TestSpecs(
      id:      1,
      info:    "Single signer, no votes cast",
      signers: @["A"],
      votes:   @[TesterVote(signer: "A")],
      results: @["A"]),

    TestSpecs(
      id:      2,
      info:    "Single signer, voting to add two others (only accept first, "&
               "second needs 2 votes)",
      signers: @["A"],
      votes:   @[TesterVote(signer: "A", voted: "B", auth: true),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "A", voted: "C", auth: true)],
      results: @["A", "B"]),

    TestSpecs(
      id:      3,
      info:    "Two signers, voting to add three others (only accept first " &
               "two, third needs 3 votes already)",
      signers: @["A", "B"],
      votes:   @[TesterVote(signer: "A", voted: "C", auth: true),
                 TesterVote(signer: "B", voted: "C", auth: true),
                 TesterVote(signer: "A", voted: "D", auth: true, noTurn: true),
                 TesterVote(signer: "B", voted: "D", auth: true),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A", voted: "E", auth: true, noTurn: true),
                 TesterVote(signer: "B", voted: "E", auth: true, noTurn: true)],
      results: @["A", "B", "C", "D"]),

    TestSpecs(
      id:      4,
      info:    "Single signer, dropping itself (weird, but one less " &
               "cornercase by explicitly allowing this)",
      signers: @["A"],
      votes:   @[TesterVote(signer: "A", voted: "A")]),

    TestSpecs(
      id:      5,
      info:    "Two signers, actually needing mutual consent to drop either " &
               "of them (not fulfilled)",
      signers: @["A", "B"],
      votes:   @[TesterVote(signer: "A", voted: "B")],
      results: @["A", "B"]),

    TestSpecs(
      id:      6,
      info:    "Two signers, actually needing mutual consent to drop either " &
               "of them (fulfilled)",
      signers: @["A", "B"],
      votes:   @[TesterVote(signer: "A", voted: "B"),
                 TesterVote(signer: "B", voted: "B")],
      results: @["A"]),

    TestSpecs(
      id:      7,
      info:    "Three signers, two of them deciding to drop the third",
      signers: @["A", "B", "C"],
      votes:   @[TesterVote(signer: "A", voted: "C",             noTurn: true),
                 TesterVote(signer: "B", voted: "C",             noTurn: true)],
      results: @["A", "B"]),

    TestSpecs(
      id:      8,
      info:    "Four signers, consensus of two not being enough to drop anyone",
      signers: @["A", "B", "C", "D"],
      votes:   @[TesterVote(signer: "A", voted: "C",             noTurn: true),
                 TesterVote(signer: "B", voted: "C",             noTurn: true)],
      results: @["A", "B", "C", "D"]),

    TestSpecs(
      id:      9,
      info:    "Four signers, consensus of three already being enough to " &
               "drop someone",
      signers: @["A", "B", "C", "D"],
      votes:   @[TesterVote(signer: "A", voted: "D",             noTurn: true),
                 TesterVote(signer: "B", voted: "D",             noTurn: true),
                 TesterVote(signer: "C", voted: "D",             noTurn: true)],
      results: @["A", "B", "C"]),

    TestSpecs(
      id:      10,
      info:    "Authorizations are counted once per signer per target",
      signers: @["A", "B"],
      votes:   @[TesterVote(signer: "A", voted: "C", auth: true),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "A", voted: "C", auth: true),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "A", voted: "C", auth: true)],
      results: @["A", "B"]),

    TestSpecs(
      id:      11,
      info:    "Authorizing multiple accounts concurrently is permitted",
      signers: @["A", "B"],
      votes:   @[TesterVote(signer: "A", voted: "C", auth: true),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "A", voted: "D", auth: true),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "A"),
                 TesterVote(signer: "B", voted: "D", auth: true),
                 TesterVote(signer: "A",                         noTurn: true),
                 TesterVote(signer: "B", voted: "C", auth: true, noTurn: true)],
      results: @["A", "B", "C", "D"]),

    TestSpecs(
      id:      12,
      info:    "Deauthorizations are counted once per signer per target",
      signers: @["A", "B"],
      votes:   @[TesterVote(signer: "A", voted: "B"),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "A", voted: "B"),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "A", voted: "B")],
      results: @["A", "B"]),

    TestSpecs(
      id:      13,
      info:    "Deauthorizing multiple accounts concurrently is permitted",
      signers: @["A", "B", "C", "D"],
      votes:   @[TesterVote(signer: "A", voted: "C",             noTurn: true),
                 TesterVote(signer: "B",                         noTurn: true),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A", voted: "D",             noTurn: true),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A"),
                 TesterVote(signer: "B", voted: "D",             noTurn: true),
                 TesterVote(signer: "C", voted: "D",             noTurn: true),
                 TesterVote(signer: "A",                         noTurn: true),
                 TesterVote(signer: "B", voted: "C",             noTurn: true)],
      results: @["A", "B"]),

    TestSpecs(
      id:      14,
      info:    "Votes from deauthorized signers are discarded immediately " &
               "(deauth votes)",
      signers: @["A", "B", "C"],
      votes:   @[TesterVote(signer: "C", voted: "B",             noTurn: true),
                 TesterVote(signer: "A", voted: "C"),
                 TesterVote(signer: "B", voted: "C",             noTurn: true),
                 TesterVote(signer: "A", voted: "B",             noTurn: true)],
      results: @["A", "B"]),

    TestSpecs(
      id:      15,
      info:    "Votes from deauthorized signers are discarded immediately " &
               "(auth votes)",
      signers: @["A", "B", "C"],
      votes:   @[TesterVote(signer: "C", voted: "D", auth: true, noTurn: true),
                 TesterVote(signer: "A", voted: "C"),
                 TesterVote(signer: "B", voted: "C",             noTurn: true),
                 TesterVote(signer: "A", voted: "D", auth: true, noTurn: true)],
      results: @["A", "B"]),

    TestSpecs(
      id:      16,
      info:    "Cascading changes are not allowed, only the account being " &
               "voted on may change",
      signers: @["A", "B", "C", "D"],
      votes:   @[TesterVote(signer: "A", voted: "C",             noTurn: true),
                 TesterVote(signer: "B",                         noTurn: true),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A", voted: "D",             noTurn: true),
                 TesterVote(signer: "B", voted: "C"),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A"),
                 TesterVote(signer: "B", voted: "D",             noTurn: true),
                 TesterVote(signer: "C", voted: "D",             noTurn: true)],
      results: @["A", "B", "C"]),

    TestSpecs(
      id:      17,
      info:    "Changes reaching consensus out of bounds (via a deauth) " &
               "execute on touch",
      signers: @["A", "B", "C", "D"],
      votes:   @[TesterVote(signer: "A", voted: "C",             noTurn: true),
                 TesterVote(signer: "B",                         noTurn: true),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A", voted: "D",             noTurn: true),
                 TesterVote(signer: "B", voted: "C"),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A"),
                 TesterVote(signer: "B", voted: "D",             noTurn: true),
                 TesterVote(signer: "C", voted: "D",             noTurn: true),
                 TesterVote(signer: "A",                         noTurn: true),
                 TesterVote(signer: "C", voted: "C", auth: true, noTurn: true)],
      results: @["A", "B"]),

    TestSpecs(
      id:      18,
      info:    "Changes reaching consensus out of bounds (via a deauth) " &
               "may go out of consensus on first touch",
      signers: @["A", "B", "C", "D"],
      votes:   @[TesterVote(signer: "A", voted: "C",             noTurn: true),
                 TesterVote(signer: "B",                         noTurn: true),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A", voted: "D",             noTurn: true),
                 TesterVote(signer: "B", voted: "C"),
                 TesterVote(signer: "C",                         noTurn: true),
                 TesterVote(signer: "A"),
                 TesterVote(signer: "B", voted: "D",             noTurn: true),
                 TesterVote(signer: "C", voted: "D",             noTurn: true),
                 TesterVote(signer: "A",                         noTurn: true),
                 TesterVote(signer: "B", voted: "C", auth: true, noTurn: true)],
      results: @["A", "B", "C"]),

    TestSpecs(
      id:      19,
      info:    "Ensure that pending votes don't survive authorization status " &
               "changes. This corner case can only appear if a signer is " &
               "quickly added, removed and then readded (or the inverse), " &
               "while one of the original voters dropped. If a past vote is " &
               "left cached in the system somewhere, this will interfere " &
               "with the final signer outcome.",
      signers: @["A", "B", "C", "D", "E"],
      votes:   @[
        # Authorize F, 3 votes needed
        TesterVote(signer: "A", voted: "F", auth: true,          noTurn: true),
        TesterVote(signer: "B", voted: "F", auth: true),
        TesterVote(signer: "C", voted: "F", auth: true,          noTurn: true),

        # Deauthorize F, 4 votes needed (leave A's previous vote "unchanged")
        TesterVote(signer: "D", voted: "F",                      noTurn: true),
        TesterVote(signer: "E", voted: "F",                      noTurn: true),
        TesterVote(signer: "B", voted: "F",                      noTurn: true),
        TesterVote(signer: "C", voted: "F"),

        # Almost authorize F, 2/3 votes needed
        TesterVote(signer: "D", voted: "F", auth: true),
        TesterVote(signer: "E", voted: "F", auth: true,          noTurn: true),

        # Deauthorize A, 3 votes needed
        TesterVote(signer: "B", voted: "A",                      noTurn: true),
        TesterVote(signer: "C", voted: "A"),
        TesterVote(signer: "D", voted: "A",                      noTurn: true),

        # Finish authorizing F, 3/3 votes needed
        TesterVote(signer: "B", voted: "F", auth: true,          noTurn: true)],
      results: @["B", "C", "D", "E", "F"]),

    TestSpecs(
      id:      20,
      info:    "Epoch transitions reset all votes to allow chain checkpointing",
      epoch:   3,
      signers: @["A", "B"],
      votes:   @[TesterVote(signer: "A", voted: "C", auth: true),
                 TesterVote(signer: "B"),
                 TesterVote(signer: "A", checkpoint: @["A", "B"]),
                 TesterVote(signer: "B", voted: "C", auth: true)],
      results: @["A", "B"]),

    TestSpecs(
      id:      21,
      info:    "An unauthorized signer should not be able to sign blocks",
      signers: @["A"],
      votes:   @[TesterVote(signer: "B",                         noTurn: true)],
      failure: errUnauthorizedSigner),

    TestSpecs(
      id:      22,
      info:    "An authorized signer that signed recenty should not be able " &
               "to sign again",
      signers: @["A", "B"],
      votes:   @[TesterVote(signer: "A"),
                 TesterVote(signer: "A")],
      failure: errRecentlySigned),

    TestSpecs(
      id:      23,
      info:    "Recent signatures should not reset on checkpoint blocks " &
               "imported in a batch ",
      epoch:   3,
      signers: @["A", "B", "C"],
      votes:   @[TesterVote(signer: "A",                         noTurn: true),
                 TesterVote(signer: "B",                         noTurn: true),
                 TesterVote(signer: "A", checkpoint: @["A", "B", "C"],
                                                                 noTurn: true),
                 TesterVote(signer: "A",                         noTurn: true)],

      # Setting the `runBack` flag forces the shapshot handler searching for
      # a checkpoint before entry 3. So the checkpont will be ignored for
      # re-setting the system so that address `A` of block #3 is found in the
      # list of recent signers (see documentation of the flag
      # `applySnapsMinBacklog` for the `Clique` descriptor.)
      #
      # As far as I understand, there was no awareness of the tranaction batch
      # in the Go implementation -- jordan.
      runBack: true,
      failure: errRecentlySigned),

    # The last test does not differ from the previous one with the current
    # test environment.
    TestSpecs(
      id:      24,
      info:    "Recent signatures (revisted) should not reset on checkpoint " &
               "blocks imported in a batch " &
               "(https://github.com/ethereum/go-ethereum/issues/17593). "&
               "Whilst this seems overly specific and weird, it was a "&
               "Rinkeby consensus split.",
      epoch:   3,
      signers: @["A", "B", "C"],
      votes:   @[TesterVote(signer: "A",                         noTurn: true),
                 TesterVote(signer: "B",                         noTurn: true),
                 TesterVote(signer: "A", checkpoint: @["A", "B", "C"],
                                                                 noTurn: true),
                 TesterVote(signer: "A", newbatch: true,         noTurn: true)],

      # Setting the `runBack` flag forces the shapshot handler searching for
      # a checkpoint before entry 3. So the checkpont will be ignored for
      # re-setting the system so that address `A` of block #3 is found in the
      # list of recent signers (see documentation of the flag
      # `applySnapsMinBacklog` for the `Clique` descriptor.)
      #
      # As far as I understand, there was no awareness of the tranaction batch
      # in the Go implementation -- jordan.
      runBack: true,
      failure: errRecentlySigned),

    # Not found in Go reference implementation
    TestSpecs(
      id:      25,
      info:    "Test 23/24 with using the most recent <epoch> checkpoint",
      epoch:   3,
      signers: @["A", "B", "C"],
      votes:   @[TesterVote(signer: "A",                         noTurn: true),
                 TesterVote(signer: "B",                         noTurn: true),
                 TesterVote(signer: "A", checkpoint: @["A", "B", "C"],
                                                                 noTurn: true),
                 TesterVote(signer: "A",                         noTurn: true)],
      results: @["A", "B", "C"])]

static:
  # For convenience, make sure that IDs are increasing
  for n in 1 ..< voterSamples.len:
    if voterSamples[n-1].id < voterSamples[n].id:
      continue
    echo "voterSamples[", n, "] == ", voterSamples[n].id, " expected ",
      voterSamples[n-1].id + 1, " or greater"
    doAssert voterSamples[n-1].id < voterSamples[n].id

# End
