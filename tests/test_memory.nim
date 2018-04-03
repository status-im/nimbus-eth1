import  unittest, macros, strformat, strutils, sequtils,
        ttmath,
        ../src/[constants, opcode_values, errors, vm/memory]

proc memory32: Memory =
  result = newMemory()
  result.extend(0.u256, 32.u256)

proc memory128: Memory =
  result = newMemory()
  result.extend(0.u256, 128.u256)

suite "memory":
  test "write":
    var mem = memory32()
    # Test that write creates 32byte string == value padded with zeros
    mem.write(startPosition = 0.u256, size = 4.u256, value = @[1.byte, 0.byte, 1.byte, 0.byte])
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

  test "write rejects invalid size":
    # expect(ValidationError):
    #   var mem = memory32()
    #   mem.write(startPosition = 0.i256, size = -1.i256, value = @[1.byte, 0.byte])
    expect(ValidationError):
      var mem = memory32()
      mem.write(startPosition = 0.u256, size = pow(2.u256, 256), value = @[1.byte, 0.byte])

  test "write rejects invalid value":
    expect(ValidationError):
      var mem = memory32()
      mem.write(startPosition = 0.u256, size = 4.u256, value = @[1.byte, 0.byte])

  test "write rejects valyes beyond memory size":
    expect(ValidationError):
      var mem = memory128()
      mem.write(startPosition = 128.u256, size = 4.u256, value = @[1.byte, 0.byte, 1.byte, 0.byte])

  test "extends appropriately extends memory":
    var mem = newMemory()
    # Test extends to 32 byte array: 0 < (start_position + size) <= 32
    mem.extend(startPosition = 0.u256, size = 10.u256)
    check(mem.bytes == repeat(0.byte, 32))
    # Test will extend past length if params require: 32 < (start_position + size) <= 64
    mem.extend(startPosition = 28.u256, size = 32.u256)
    check(mem.bytes == repeat(0.byte, 64))
    # Test won't extend past length unless params require: 32 < (start_position + size) <= 64
    mem.extend(startPosition = 48.u256, size = 10.u256)
    check(mem.bytes == repeat(0.byte, 64))

  test "read returns correct bytes":
    var mem = memory32()
    mem.write(startPosition = 5.u256, size = 4.u256, value = @[1.byte, 0.byte, 1.byte, 0.byte])
    check(mem.read(startPosition = 5.u256, size = 4.u256) == @[1.byte, 0.byte, 1.byte, 0.byte])
    check(mem.read(startPosition = 6.u256, size = 4.u256) == @[0.byte, 1.byte, 0.byte, 0.byte])
    check(mem.read(startPosition = 1.u256, size = 3.u256) == @[0.byte, 0.byte, 0.byte])
