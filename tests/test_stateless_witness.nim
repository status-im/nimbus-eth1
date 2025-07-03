# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  unittest2,
  ../execution_chain/stateless/witness

suite "Execution Witness Tests":

  test "Encoding/decoding empty witness":
    var witness: ExecutionWitness

    let witnessBytes = witness.encode()
    check witnessBytes.len() > 0
    echo witnessBytes

    let decodedWitness = ExecutionWitness.decode(witnessBytes)
    check:
      decodedWitness.isOk()
      decodedWitness.get() == witness

  test "Encoding/decoding witness":
    var witness = ExecutionWitness.init()
    witness.addState(@[0x1.byte, 0x2, 0x3])
    witness.addCode(@[0x4.byte, 0x5, 0x6])
    witness.addKey(@[0x7.byte, 0x8, 0x9])
    witness.addHeader(Header())

    let witnessBytes = witness.encode()
    check witnessBytes.len() > 0
    echo witnessBytes

    let decodedWitness = ExecutionWitness.decode(witnessBytes)
    check:
      decodedWitness.isOk()
      decodedWitness.get() == witness
