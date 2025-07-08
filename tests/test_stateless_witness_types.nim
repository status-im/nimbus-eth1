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
  ../execution_chain/stateless/witness_types

suite "Stateless: Witness Types":

  test "Encoding/decoding empty Witness":
    var witness: Witness

    let witnessBytes = witness.encode()
    check witnessBytes.len() > 0

    let decodedWitness = Witness.decode(witnessBytes)
    check:
      decodedWitness.isOk()
      decodedWitness.get() == witness

  test "Encoding/decoding Witness":
    var witness = Witness.init()
    witness.addState(@[0x1.byte, 0x2, 0x3])
    witness.addKey(@[0x7.byte, 0x8, 0x9])
    witness.addCodeHash(EMPTY_ROOT_HASH)
    witness.addHeaderHash(EMPTY_ROOT_HASH)

    let witnessBytes = witness.encode()
    check witnessBytes.len() > 0

    let decodedWitness = Witness.decode(witnessBytes)
    check:
      decodedWitness.isOk()
      decodedWitness.get() == witness

  test "Encoding/decoding empty ExecutionWitness":
    var witness: ExecutionWitness

    let witnessBytes = witness.encode()
    check witnessBytes.len() > 0

    let decodedWitness = ExecutionWitness.decode(witnessBytes)
    check:
      decodedWitness.isOk()
      decodedWitness.get() == witness

  test "Encoding/decoding ExecutionWitness":
    var witness = ExecutionWitness.init()
    witness.addState(@[0x1.byte, 0x2, 0x3])
    witness.addKey(@[0x7.byte, 0x8, 0x9])
    witness.addCode(@[0x4.byte, 0x5, 0x6])
    witness.addHeader(Header())

    let witnessBytes = witness.encode()
    check witnessBytes.len() > 0

    let decodedWitness = ExecutionWitness.decode(witnessBytes)
    check:
      decodedWitness.isOk()
      decodedWitness.get() == witness
