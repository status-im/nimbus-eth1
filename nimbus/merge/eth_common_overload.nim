import eth/common

template prevRandao*(h: BlockHeader | BlockHeaderRef): Hash256 =
  h.mixDigest

template `prevRandao=`*(h: BlockHeader | BlockHeaderRef, hash: Hash256) =
  h.mixDigest = hash
