# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import results, eth/common, ../../nimbus/db/era1_db

var noisy* = false

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpBlocksEra1*(
    dir: string,
    least = low(uint64), # First block to extract
    stopAfter = high(uint64), # Last block to extract
): seq[EthBlock] =
  let db = Era1DbRef.init(dir, "mainnet").expect("Era files present")
  defer:
    db.dispose()

  # TODO it would be a lot more natural for this iterator to return 1 block at
  #      a time and let the consumer do the chunking
  const blocksPerYield = 192
  var tmp = newSeqOfCap[EthBlock](blocksPerYield)

  for i in 0 ..< stopAfter:
    var bck = db.getEthBlock(least + i).valueOr:
      doAssert i > 0, "expected at least one block"
      break

    tmp.add move(bck)

    # Genesis block requires a chunk of its own, for compatibility with current
    # test setup (a bit weird, that...)
    if tmp.len mod blocksPerYield == 0 or tmp[0].header.number == 0:
      yield tmp
      tmp.setLen(0)

  if tmp.len > 0:
    yield tmp

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
