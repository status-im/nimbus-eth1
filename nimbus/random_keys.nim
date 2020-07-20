import eth/keys, config

proc getRng*(): ref BrHmacDrbgContext =
  getConfiguration().rng

proc randomPrivateKey*(): PrivateKey =
  random(PrivateKey, getRng()[])

proc randomKeyPair*(): KeyPair =
  random(KeyPair, getRng()[])
