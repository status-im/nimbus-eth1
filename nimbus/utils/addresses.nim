import nimcrypto, eth_common, rlp

proc generateAddress*(address: EthAddress, nonce: AccountNonce): EthAddress =
  result[0..19] = keccak256.digest(rlp.encodeList(address, nonce).toOpenArray).data[12..31]
