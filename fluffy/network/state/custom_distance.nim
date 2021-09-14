import stint

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
proc distance*(node_id: UInt256, content_id: UInt256): UInt256 =
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
