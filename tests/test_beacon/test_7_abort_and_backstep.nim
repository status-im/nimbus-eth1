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
  stew/byteutils,
  ./setup_env,
  ../../nimbus/sync/beacon/skeleton_main,
  ../../nimbus/sync/beacon/skeleton_utils,
  ../../nimbus/sync/beacon/skeleton_db

proc ccm(cc: NetworkParams) =
  cc.config.terminalTotalDifficulty = some(262000.u256)
  cc.genesis.extraData = hexToSeqByte("0x000000000000000000")
  cc.genesis.difficulty = 1.u256

proc test7*() =
  suite "should abort filling the canonical chain and backstep if the terminal block is invalid":
    let env = setupEnv(extraValidation = true, ccm)
    let skel = SkeletonRef.new(env.chain)

    test "skel open ok":
      let res = skel.open()
      check res.isOk
      if res.isErr:
        debugEcho res.error
        check false
        break

    let
      genesis   = env.chain.com.genesisHeader
      block1    = env.chain.com.header(1, genesis, genesis,
        "6BD9564DD3F4028E3E56F62F1BE52EC8F893CC4FD7DB75DB6A1DC3EB2858998C")
      block2    = env.chain.com.header(2, block1, block1,
        "32DAA84E151F4C8C6BD4D9ADA4392488FFAFD42ACDE1E9C662B3268C911A5CCC")
      block3PoW = env.chain.com.header(3, block2, block2)
      block4InvalidPoS = header(4, block3PoW, block3PoW, 0)
      emptyBody = emptyBody()

    test "put body":
      for header in [block1, block2, block3PoW, block4InvalidPoS]:
        let res = skel.putBody(header, emptyBody)
        check res.isOk

    test "canonical height should be at genesis":
      skel.initSyncT(block4InvalidPoS, true)
      skel.putBlocksT([block3PoW, block2], 2, {})
      check skel.blockHeight == 0

    test "canonical height should stop at block 2":
      # (valid terminal block), since block 3 is invalid (past ttd)
      skel.putBlocksT([block1], 1, {FillCanonical})
      check skel.blockHeight == 2

    test "Subchain should have been backstepped to 4":
      check skel.last.tail == 4
