# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  nimcrypto,
  ./impl_std_import, ./helpers

proc sha3op*(computation: var BaseComputation) =
  let (startPosition, size) = computation.stack.popInt(2)
  let (pos, len) = (startPosition.toInt, size.toInt)

  computation.gasMeter.consumeGas(
    computation.gasCosts[Op.Sha3].m_handler(computation.memory.len, pos, len),
    reason="SHA3: word gas cost"
    )

  computation.memory.extend(pos, len)

  var res = keccak256.digest("") # TODO: stub
  pushRes()
