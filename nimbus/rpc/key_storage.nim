#
#                 Nimbus
#              (c) Copyright 2019
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import tables, eth/keys

type
  KeyStorage* = ref object
    asymKeys*: Table[string, KeyPair]

  KeyGenerationError* = object of CatchableError

proc newKeyStorage*(): KeyStorage =
  new(result)
  result.asymKeys = initTable[string, KeyPair]()
