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

proc test5*() =
  suite "should fill the canonical chain after being linked to a canonical block past genesis":
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
      block3 = header(3, genesis, block2, 100)
      block4 = header(4, genesis, block3, 100)
      block5 = header(5, genesis, block4, 100)
      emptyBody = emptyBody()

    test "put body":
      for header in [block1, block2, block3, block4, block5]:
        let res = skel.putBody(header, emptyBody)
        check res.isOk

    test "canonical height should be at block 2":
      let r = skel.insertBlocks([block1, block2], [emptyBody, emptyBody], false)
      check r.isOk
      check r.get == 2

      skel.initSyncT(block4, true)
      check skel.blockHeight == 2

    test "canonical height should update after being linked":
      skel.putBlocksT([block3], 1, {FillCanonical})
      check skel.blockHeight == 4

    test "canonical height should not change when setHead with force=false":
      skel.setHeadT(block5, false, false, {})
      check skel.blockHeight == 4

    test "canonical height should change when setHead with force=true":
      skel.setHeadT(block5, true, false, {FillCanonical})
      check skel.blockHeight == 5

    test "skel header should be cleaned up after filling canonical chain":
      let headers = [block3, block4, block5]
      skel.getHeaderClean(headers)
