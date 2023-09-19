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

proc test3*() =
  suite "should init/setHead properly from genesis":
    let env = setupEnv()
    let skel = SkeletonRef.new(env.chain)

    test "skel open ok":
      let res = skel.open()
      check res.isOk
      if res.isErr:
        debugEcho res.error
        check false
        break

    let
      genesis = env.chain.com.genesisHeader
      block1 = header(1, genesis, genesis, 100)
      block2 = header(2, genesis, block1, 100)
      block3 = header(3, genesis, block1, 100)

    test "should not reorg on genesis init":
      skel.initSyncT(genesis, false)

    test "should not reorg on genesis announcement":
      skel.setHeadT(genesis, false, false)

    test "should not reorg on genesis setHead":
      skel.setHeadT(genesis, true, false)

    test "no subchain should have been created":
      check skel.len == 0

    test "should not allow putBlocks since no subchain set":
      let r = skel.putBlocks([block1])
      check r.isErr

    test "canonical height should be at genesis":
      check skel.blockHeight == 0

    test "should not reorg on valid first block":
      skel.setHeadT(block1, false, false)

    test "no subchain should have been created":
      check skel.len == 0

    test "should not reorg on valid first block":
      skel.setHeadT(block1, true, false)

    test "subchain should have been created":
      check skel.len == 1

    test "head should be set to first block":
      check skel.last.head == 1

    test "subchain status should be linked":
      skel.isLinkedT(true)

    test "should not reorg on valid second block":
      skel.setHeadT(block2, true, false)

    test "subchain should be same":
      check skel.len == 1

    test "head should be set to first block":
      check skel.last.head == 2

    test "subchain status should stay linked":
      skel.isLinkedT(true)

    test "should not extend on invalid third block":
      skel.setHeadT(block3, false, true)

    # since its not a forced update so shouldn"t affect subchain status
    test "subchain should be same":
      check skel.len == 1

    test "head should be set to second block":
      check skel.last.head == 2

    test "subchain status should stay linked":
      skel.isLinkedT(true)

    test "should not extend on invalid third block":
      skel.setHeadT(block3, true, true)

    # since its not a forced update so shouldn"t affect subchain status
    test "new subchain should be created":
      check skel.len == 2

    test "head should be set to third block":
      check skel.last.head == 3

    test "subchain status should not be linked anymore":
      skel.isLinkedT(false)
