# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/sequtils,
  stint, unittest2,
  ../../network/state/state_distance

suite "State network custom distance function":
  test "Calculate distance according to spec":
    check:
      # Test cases from spec
      stateDistance(u256(10), u256(10)) == 0
      stateDistance(u256(5), high(UInt256)) == 6
      stateDistance(high(UInt256), u256(6)) == 7
      stateDistance(u256(5), u256(1)) == 4
      stateDistance(u256(1), u256(5)) == 4
      stateDistance(UInt256.zero, MID) == MID
      stateDistance(UInt256.zero, MID + UInt256.one) == MID - UInt256.one

      # Additional test cases to check some basic properties
      stateDistance(UInt256.zero, MID + MID) == UInt256.zero
      stateDistance(UInt256.zero, UInt256.one) == stateDistance(UInt256.zero, high(UInt256))

  test "Calculate logarithimic distance":
    check:
      stateLogDistance(u256(0), u256(0)) == 0
      stateLogDistance(u256(0), u256(1)) == 0
      stateLogDistance(u256(0), u256(2)) == 1
      stateLogDistance(u256(0), u256(4)) == 2
      stateLogDistance(u256(0), u256(8)) == 3
      stateLogDistance(u256(8), u256(0)) == 3
      stateLogDistance(UInt256.zero, MID) == 255
      stateLogDistance(UInt256.zero, MID + UInt256.one) == 254

  test "Calculate id at log distance":
    let logDistances = @[
      0'u16, 1, 2, 3, 4, 5, 6, 7, 8
    ]

    # for each log distance, calulate node-id at given distance from node zero, and then
    # log distance from calculate node-id to node zero. The results should equal
    # starting log distances
    let logCalculated = logDistances.map(
      proc (x: uint16): uint16 =
        let nodeAtDist = stateIdAtDistance(UInt256.zero, x)
        return stateLogDistance(UInt256.zero, nodeAtDist)
    )

    check:
      logDistances == logCalculated
