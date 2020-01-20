#
#                 Nimbus
#              (c) Copyright 2019
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import tables, eth/keys, eth/p2p/rlpx_protocols/whisper/whisper_types

type
  KeyStorage* = ref object
    asymKeys*: Table[string, KeyPair]
    symKeys*: Table[string, SymKey]

  KeyGenerationError* = object of CatchableError

proc newKeyStorage*(): KeyStorage =
  new(result)
  result.asymKeys = initTable[string, KeyPair]()
  result.symKeys = initTable[string, SymKey]()
