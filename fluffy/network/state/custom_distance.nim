import
  eth/p2p/discoveryv5/routing_table,
  stint

const MID* = u256(2).pow(u256(255))
const MAX* = high(Uint256)

# Custom distance function described in: https://notes.ethereum.org/h58LZcqqRRuarxx4etOnGQ#Storage-Layout
# The implementation looks different than in spec, due to the fact that in practice
# we are operating on unsigned 256bit integers instead of signed big ints.
# Thanks to this we do not need to use:
#  - modulo operations
#  - abs operation
# and the results are eqivalent to function described in spec.
# 
# The way it works is as follows. Let say we have integers modulo 8:
# [0, 1, 2, 3, 4, 5, 6, 7]
# and we want to calculate minimal distance between 0 and 5.
# Raw difference is: 5 - 0 = 5, which is larger than mid point which is equal to 4.
# From this we know that the shorter distance is the one wraping around 0, which
# is equal to 3
func distance*(node_id: UInt256, content_id: UInt256): UInt256 =
  let rawDiff = 
    if node_id > content_id:
      node_id - content_id
    else:
      content_id - node_id

  if rawDiff > MID:
    # If rawDiff is larger than mid this means that distance between node_id and 
    # content_id is smaller when going from max side.
    MAX - rawDiff + UInt256.one
  else:
    rawDiff

# TODO we do not have Uint256 log2 implementation. It would be nice to implement
# it in stint library in some more performant way. This version has O(n) complexity.
func myLog2Distance(value: UInt256): uint16 =
  # Logarithm is not defined for zero values. Implementation in stew for builtin
  # types return -1 in that case, but here it is just internal function so just make sure
  # 0 is never provided.
  doAssert(not value.isZero())

  if value == UInt256.one:
    return 0'u16
  
  var comp = value
  var ret = 0'u16
  while (comp > 1):
    comp = comp shr 1
    ret = ret + 1
  return ret

func atDistance*(id: UInt256, dist: uint16): UInt256 =
  # TODO With current distance function there are always two ids at given distance
  # so we might as well do: id - u256(dist), maybe it is worth discussing if every client
  # should use the same id in this case.
  id + u256(2).pow(dist)

func logDistance*(a, b: UInt256): uint16 = 
  let distance = distance(a, b)
  if distance.isZero():
    return 0
  else:
    return myLog2Distance(distance)

const customDistanceCalculator* =
  DistanceCalculator(
    calculateDistance: distance, 
    calculateLogDistance: logDistance, 
    calculateIdAtDistance: atDistance
  )
