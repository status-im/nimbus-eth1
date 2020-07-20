import eth/keys as ethkeys

# You should only create one instance of the RNG per application / library
# Ref is used so that it can be shared between components

var theRNG {.threadvar.}: ref BrHmacDrbgContext

proc getRng*(): ref BrHmacDrbgContext {.gcsafe.} =
  if theRNG.isNil:
    theRNG = newRng()
  theRNG

proc randomPrivateKey*(): PrivateKey =
  random(PrivateKey, getRng()[])

proc randomKeyPair*(): KeyPair =
  random(KeyPair, getRng()[])
