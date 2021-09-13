import stint

const MID* = u256(2).pow(u256(255))

proc distance*(node_id: UInt256, content_id: UInt256): UInt256 =
  let rawDiff = 
    if node_id > content_id:
      node_id - content_id
    else:
      content_id - node_id

  if rawDiff > MID:
    u256(0) - rawDiff
  else:
    rawDiff
