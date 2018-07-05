# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, sequtils,
  eth_common/eth_types,
  ../nimbus/[constants, errors, vm/memory]

proc memory32: Memory =
  result = newMemory()
  result.extend(0, 32)

proc memory128: Memory =
  result = newMemory()
  result.extend(0, 128)

suite "memory":
  test "write":
    var mem = memory32()
    # Test that write creates 32byte string == value padded with zeros
    mem.write(startPosition = 0, value = @[1.byte, 0.byte, 1.byte, 0.byte])
    check(mem.bytes == @[1.byte, 0.byte, 1.byte, 0.byte].concat(repeat(0.byte, 28)))

  # test "write rejects invalid position":
  #   expect(ValidationError):
  #     var mem = memory32()
  #     mem.write(startPosition = -1.i256, size = 2.i256, value = @[1.byte, 0.byte])
    # expect(ValidationError):
      # TODO: work on 256
      # var mem = memory32()
      # echo "pow ", pow(2.i256, 255) - 1.i256
      # mem.write(startPosition = pow(2.i256, 256), size = 2.i256, value = @[1.byte, 0.byte])

  # test "write rejects invalid size":
  #   # expect(ValidationError):
  #   #   var mem = memory32()
  #   #   mem.write(startPosition = 0.i256, size = -1.i256, value = @[1.byte, 0.byte])

  #   #TODO deactivated because of no pow support in Stint: https://github.com/status-im/nim-stint/issues/37
  #   expect(ValidationError):
  #     var mem = memory32()
  #     mem.write(startPosition = 0.u256, size = pow(2.u256, 256), value = @[1.byte, 0.byte])

  test "write rejects valyes beyond memory size":
    expect(ValidationError):
      var mem = memory128()
      mem.write(startPosition = 128, value = @[1.byte, 0.byte, 1.byte, 0.byte])

  test "extends appropriately extends memory":
    var mem = newMemory()
    # Test extends to 32 byte array: 0 < (start_position + size) <= 32
    mem.extend(startPosition = 0, size = 10)
    check(mem.bytes == repeat(0.byte, 32))
    # Test will extend past length if params require: 32 < (start_position + size) <= 64
    mem.extend(startPosition = 28, size = 32)
    check(mem.bytes == repeat(0.byte, 64))
    # Test won't extend past length unless params require: 32 < (start_position + size) <= 64
    mem.extend(startPosition = 48, size = 10)
    check(mem.bytes == repeat(0.byte, 64))

  test "read returns correct bytes":
    var mem = memory32()
    mem.write(startPosition = 5, value = @[1.byte, 0.byte, 1.byte, 0.byte])
    check(mem.read(startPosition = 5, size = 4) == @[1.byte, 0.byte, 1.byte, 0.byte])
    check(mem.read(startPosition = 6, size = 4) == @[0.byte, 1.byte, 0.byte, 0.byte])
    check(mem.read(startPosition = 1, size = 3) == @[0.byte, 0.byte, 0.byte])
