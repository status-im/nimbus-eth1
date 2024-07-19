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
  ../../nimbus/sync/beacon/skeleton_utils

# Tests that a running skeleton sync can be extended with properly linked up
# headers but not with side chains.

type TestCase = object
  name: string
  blocks: seq[BlockHeader] # Database content (besides the genesis)
  head: BlockHeader # New head header to announce to reorg to
  extend: BlockHeader # New head header to announce to extend with
  force: bool # To force set head not just to extend
  newState: seq[Subchain] # Expected sync state after the reorg
  err: Opt[SkeletonStatus] # Whether extension succeeds or not

let testCases = [
  # Initialize a sync and try to extend it with a subsequent block.
  TestCase(
    name: "Initialize a sync and try to extend it with a subsequent block",
    head: block49,
    extend: block50,
    force: true,
    newState: @[subchain(50, 49)],
  ),
  # Initialize a sync and try to extend it with the existing head block.
  TestCase(
    name: "Initialize a sync and try to extend it with the existing head block",
    blocks: @[block49],
    head: block49,
    extend: block49,
    newState: @[subchain(49, 49)],
  ),
  # Initialize a sync and try to extend it with a sibling block.
  TestCase(
    name: "Initialize a sync and try to extend it with a sibling block",
    head: block49,
    extend: block49B,
    newState: @[subchain(49, 49)],
    err: Opt.some ReorgDenied,
  ),
  # Initialize a sync and try to extend it with a number-wise sequential
  # header, but a hash wise non-linking one.
  TestCase(
    name:
      "Initialize a sync and try to extend it with a number-wise sequential alternate block",
    head: block49B,
    extend: block50,
    newState: @[subchain(49, 49)],
    err: Opt.some ReorgDenied,
  ),
  # Initialize a sync and try to extend it with a non-linking future block.
  TestCase(
    name: "Initialize a sync and try to extend it with a non-linking future block",
    head: block49,
    extend: block51,
    newState: @[subchain(49, 49)],
    err: Opt.some ReorgDenied,
  ),
  # Initialize a sync and try to extend it with a past canonical block.
  TestCase(
    name: "Initialize a sync and try to extend it with a past canonical block",
    head: block50,
    extend: block49,
    newState: @[subchain(50, 50)],
    err: Opt.some ReorgDenied,
  ),
  # Initialize a sync and try to extend it with a past sidechain block.
  TestCase(
    name: "Initialize a sync and try to extend it with a past sidechain block",
    head: block50,
    extend: block49B,
    newState: @[subchain(50, 50)],
    err: Opt.some ReorgDenied,
  ),
]

proc test2*() =
  suite "Tests that a running skeleton sync can be extended":
    for z in testCases:
      test z.name:
        let env = setupEnv()
        let skel = SkeletonRef.new(env.chain)
        let res = skel.open()
        check res.isOk
        if res.isErr:
          debugEcho res.error
          check false
          break

        let x = skel.initSync(z.head).valueOr:
          debugEcho "initSync: ", error
          check false
          break

        check x.status.card == 0
        check x.reorg == true

        let r = skel.setHead(z.extend, z.force, false, true).valueOr:
          debugEcho "setHead: ", error
          check false
          break

        if z.err.isSome:
          check r.status.card == 1
          check z.err.get in r.status
        else:
          check r.status.card == 0

        check skel.len == z.newState.len
        for i, sc in skel:
          check sc.head == z.newState[i].head
          check sc.tail == z.newState[i].tail
