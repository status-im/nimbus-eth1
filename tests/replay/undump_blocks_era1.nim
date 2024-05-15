# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  results,
  eth/common,
  ../../nimbus/db/core_db,
  ../../fluffy/eth_data/era1

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpBlocksEra1*(eFile: string): (seq[BlockHeader],seq[BlockBody]) =
  ## Variant of `undumpBlocks()`
  var headers: seq[BlockHeader]
  var bodies: seq[BlockBody]
  let era1File = Era1File.open(eFile).valueOr:
    raiseAssert "Cannot open " & eFile & ": " & $error
  for blockTuple in era1File.era1BlockTuples:
    if blockTuple.header.blockNumber == 0:
      yield (@[blockTuple.header], @[blockTuple.body])
    else:
      headers.add blockTuple.header
      bodies.add blockTuple.body
      if 192 <= headers.len:
        yield (headers, bodies)
        headers.setLen 0
        bodies.setLen 0
  if headers.len > 0:
    yield (headers, bodies)
    headers.setLen 0
    bodies.setLen 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
