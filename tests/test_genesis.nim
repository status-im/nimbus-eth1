import unittest, ../nimbus/[genesis, config], eth/common, nimcrypto/hash

suite "Genesis":
  test "Correct mainnet hash":
    let g = defaultGenesisBlockForNetwork(MainNet)
    let b = g.toBlock
    check(b.blockHash == "D4E56740F876AEF8C010B86A40D5F56745A118D0906A34E69AEC8C0DB1CB8FA3".toDigest)
