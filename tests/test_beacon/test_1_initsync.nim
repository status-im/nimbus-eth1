# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  unittest2,
  ./setup_env,
  ../../nimbus/sync/beacon/skeleton_main,
  ../../nimbus/sync/beacon/skeleton_utils,
  ../../nimbus/sync/beacon/skeleton_db

type
  TestCase = object
    name    : string
    blocks  : seq[BlockHeader] # Database content (besides the genesis)
    oldState: seq[Subchain]    # Old sync state with various interrupted subchains
    head    : BlockHeader      # New head header to announce to reorg to
    newState: seq[Subchain]    # Expected sync state after the reorg
    reorg   : bool

let testCases = [
  # The sync is expected to create a single subchain with the requested head.
  TestCase(
    name: "Completely empty database with only the genesis set.",
    head: block50,
    newState: @[subchain(50, 50)],
    reorg: true
  ),
  # This is a synthetic case, just for the sake of covering things.
  TestCase(
    name: "Empty database with only the genesis set with a leftover empty sync progress",
    head: block50,
    newState: @[subchain(50, 50)],
    reorg: true
  ),
  # The old subchain should be left as is and a new one appended to the sync status.
  TestCase(
    name: "A single leftover subchain is present, older than the new head.",
    oldState: @[subchain(10, 5)],
    head: block50,
    newState: @[
      subchain(10, 5),
      subchain(50, 50),
    ],
    reorg: true
  ),
  # The old subchains should be left as is and a new one appended to the sync status.
  TestCase(
    name: "Multiple leftover subchains are present, older than the new head.",
    oldState: @[
      subchain(10, 5),
      subchain(20, 15),
    ],
    head: block50,
    newState: @[
      subchain(10, 5),
      subchain(20, 15),
      subchain(50, 50),
    ],
    reorg: true
  ),
  # The newer subchain should be deleted and a fresh one created for the head.
  TestCase(
    name: "A single leftover subchain is present, newer than the new head.",
    oldState: @[subchain(65, 60)],
    head: block50,
    newState: @[subchain(50, 50)],
    reorg: true
  ),
  # The newer subchains should be deleted and a fresh one created for the head.
  TestCase(
    name: "Multiple leftover subchain is present, newer than the new head.",
    oldState: @[
      subchain(65, 60),
      subchain(75, 70),
    ],
    head: block50,
    newState: @[subchain(50, 50)],
    reorg: true
  ),
  # than the announced head. The head should delete the newer one,
  # keeping the older one.
  TestCase(
    name: "Two leftover subchains are present, one fully older and one fully newer",
    oldState: @[
      subchain(10, 5),
      subchain(65, 60),
    ],
    head: block50,
    newState: @[
      subchain(10, 5),
      subchain(50, 50),
    ],
    reorg: true
  ),
  # than the announced head. The head should delete the newer
  # ones, keeping the older ones.
  TestCase(
    name: "Multiple leftover subchains are present, some fully older and some fully newer",
    oldState: @[
      subchain(10, 5),
      subchain(20, 15),
      subchain(65, 60),
      subchain(75, 70),
    ],
    head: block50,
    newState: @[
      subchain(10, 5),
      subchain(20, 15),
      subchain(50, 50),
    ],
    reorg: true
  ),
  # it with one more header. We expect the subchain head to be pushed forward.
  TestCase(
    name: "A single leftover subchain is present and the new head is extending",
    blocks: @[block49],
    oldState: @[subchain(49, 5)],
    head: block50,
    newState: @[subchain(50, 5)],
    reorg: false
  ),
  # A single leftover subchain is present. A new head is announced that
  # links into the middle of it, correctly anchoring into an existing
  # header. We expect the old subchain to be truncated and extended with
  # the new head.
  TestCase(
    name: "Duplicate announcement should not modify subchain",
    blocks: @[block49, block50],
    oldState: @[subchain(100, 5)],
    head: block50,
    newState: @[subchain(100, 5)],
    reorg: false
  ),
  # A single leftover subchain is present. A new head is announced that
  # links into the middle of it, correctly anchoring into an existing
  # header. We expect the old subchain to be truncated and extended with
  # the new head.
  TestCase(
    name: "A new alternate head is announced in the middle should truncate subchain",
    blocks: @[block49, block50],
    oldState: @[subchain(100, 5)],
    head: block50B,
    newState: @[subchain(50, 5)],
    reorg: true
  ),
  # A single leftover subchain is present. A new head is announced that
  # links into the middle of it, but does not anchor into an existing
  # header. We expect the old subchain to be truncated and a new chain
  # be created for the dangling head.
  TestCase(
    name: "The old subchain to be truncated and a new chain be created for the dangling head",
    blocks: @[block49B],
    oldState: @[subchain(100, 5)],
    head: block50,
    newState: @[
      subchain(49, 5),
      subchain(50, 50),
    ],
    reorg: true
  ),
  ]

proc test1*() =
  suite "Tests various sync initializations":
    # based on previous leftovers in the database
    # and announced heads.
    for z in testCases:
      test z.name:
        let env = setupEnv()
        let skel = SkeletonRef.new(env.chain)
        let res = skel.open()
        check res.isOk
        if res.isErr:
          debugEcho res.error
          break

        for header in z.blocks:
          skel.putHeader(header)

        for x in z.oldState:
          skel.push(x.head, x.tail, default(Hash256))

        let r = skel.initSync(z.head).valueOr:
          debugEcho "initSync: ", error
          check false
          break

        check r.status.card == 0
        check r.reorg == z.reorg

        check skel.len == z.newState.len
        for i, sc in skel:
          check sc.head == z.newState[i].head
          check sc.tail == z.newState[i].tail
