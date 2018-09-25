import nimcrypto, eth_common, rlp

func generateAddress*(address: EthAddress, nonce: AccountNonce): EthAddress =
  result[0..19] = keccak256.digest(rlp.encodeList(address, nonce)).data.toOpenArray(12, 31)
