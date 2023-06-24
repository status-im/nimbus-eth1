# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

include eth/common/eth_types_rlp

# reexport private procs

template decodeTxLegacy*(rlp: var Rlp, tx: var Transaction) =
  readTxLegacy(rlp, tx)

template decodeTxTyped*(rlp: var Rlp, tx: var Transaction) =
  readTxTyped(rlp, tx)
