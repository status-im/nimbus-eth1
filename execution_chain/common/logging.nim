# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  std/typetraits,
  json_serialization/std/net as jsnet,
  web3/conversions,
  confutils/defs,
  eth/common/eth_types_json_serialization

export conversions.writeValue, jsnet.writeValue, eth_types_json_serialization.writeValue

# nim-confutils
proc writeValue*(
    w: var JsonWriter, v: InputFile | OutDir | OutFile | RestOfCmdLine | OutPath
) {.inline, raises: [IOError].} =
  w.writeValue distinctBase(v)
