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
  test_1_initsync,
  test_2_extend,
  test_3_sethead_genesis,
  test_4_fill_canonical,
  test_5_canonical_past_genesis,
  test_6_abort_filling,
  test_7_abort_and_backstep,
  test_8_pos_too_early,
  ../../nimbus/sync/beacon/skeleton_main,
  ./setup_env

proc ccm(cc: NetworkParams) =
  cc.config.terminalTotalDifficulty = none(UInt256)
  cc.genesis.difficulty = 1.u256

proc skeletonMain*() =
  test1()
  test2()
  test3()
  test4()
  test5()
  test6()
  test7()
  test8()

  suite "skeleton open should error if ttd not set":
    let env = setupEnv(extraValidation = true, ccm)
    let skel = SkeletonRef.new(env.chain)

    test "skel open error":
      let res = skel.open()
      check res.isErr

when isMainModule:
  skeletonMain()
