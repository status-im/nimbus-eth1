# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits, net],
  json_serialization,
  web3/primitives,
  confutils/defs,
  eth/common/eth_types_json_serialization

# nim-eth
proc writeValue*(
    w: var JsonWriter, v: EthTime | NetworkId | ChainId
) {.inline, raises: [IOError].} =
  w.writeValue distinctBase(v)

# nim-web3
proc writeValue*(w: var JsonWriter, v: Quantity) {.inline, raises: [IOError].} =
  w.writeValue distinctBase(v)

# nim-confutils
proc writeValue*(
    w: var JsonWriter, v: InputFile | OutDir | OutFile | RestOfCmdLine | OutPath
) {.inline, raises: [IOError].} =
  w.writeValue distinctBase(v)

# build-system
proc writeValue*(w: var JsonWriter, v: Port) {.inline, raises: [IOError].} =
  w.writeValue distinctBase(v)
