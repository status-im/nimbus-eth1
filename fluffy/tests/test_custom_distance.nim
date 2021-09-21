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
  ../network/state/custom_distance

suite "State network custom distance function":
  test "Calculate distance according to spec":
    check:
      # Test cases from spec
      distance(u256(10), u256(10)) == 0
      distance(u256(5), high(UInt256)) == 6
      distance(high(UInt256), u256(6)) == 7
      distance(u256(5), u256(1)) == 4
      distance(u256(1), u256(5)) == 4
      distance(UInt256.zero, MID) == MID
      distance(UInt256.zero, MID + UInt256.one) == MID - UInt256.one

      # Additional test cases to check some basic properties
      distance(UInt256.zero, MID + MID) == UInt256.zero
      distance(UInt256.zero, UInt256.one) == distance(UInt256.zero, high(UInt256))
      
  test "Calculate logarithimic distance":
    check:
      logDistance(u256(0), u256(0)) == 0
      logDistance(u256(0), u256(1)) == 0
      logDistance(u256(0), u256(2)) == 1
      logDistance(u256(0), u256(4)) == 2
      logDistance(u256(0), u256(8)) == 3
      logDistance(u256(8), u256(0)) == 3
      logDistance(UInt256.zero, MID) == 255
      logDistance(UInt256.zero, MID + UInt256.one) == 254
  
  test "Calculate id at log distance":
    let logDistances = @[
      0'u16, 1, 2, 3, 4, 5, 6, 7, 8
    ]

    # for each log distance, calulate node-id at given distance from node zero, and then
    # log distance from calculate node-id to node zero. The results should equal
    # starting log distances
    let logCalculated = logDistances.map(
      proc (x: uint16): uint16 =
        let nodeAtDist = atDistance(Uint256.zero, x)
        return logDistance(Uint256.zero, nodeAtDist)
    )

    check:
      logDistances == logCalculated
