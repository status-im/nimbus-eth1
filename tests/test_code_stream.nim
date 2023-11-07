# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/sequtils,
  unittest2,
  stew/[byteutils, results],
  ../nimbus/vm_internals,
  ../nimbus/utils/eof,
  ../nimbus/evm/[analysis, validate],
  ../nimbus/evm/interpreter/op_codes

proc codeStreamMain*() =
  suite "parse bytecode":
    test "accepts bytes":
      let codeStream = newCodeStream("\x01")
      check(codeStream.len == 1)


    # quicktest
    # @pytest.mark.parametrize("code_bytes", (1010, '1010', True, bytearray(32)))
    # def test_codeStream_rejects_invalid_code_byte_values(code_bytes):
    #     with pytest.raises(ValidationError):
    #         CodeStream(code_bytes)

    test "next returns the correct opcode":
      var codeStream = newCodeStream("\x01\x02\x30")
      check(codeStream.next == Op.ADD)
      check(codeStream.next == Op.MUL)
      check(codeStream.next == Op.ADDRESS)


    test "peek returns next opcode without changing location":
      var codeStream = newCodeStream("\x01\x02\x30")
      check(codeStream.pc == 0)
      check(codeStream.peek == Op.ADD)
      check(codeStream.pc == 0)
      check(codeStream.next == Op.ADD)
      check(codeStream.pc == 1)
      check(codeStream.peek == Op.MUL)
      check(codeStream.pc == 1)


    test "stop opcode is returned when end reached":
      var codeStream = newCodeStream("\x01\x02")
      discard codeStream.next
      discard codeStream.next
      check(codeStream.next == Op.STOP)

    # Seek has been dommented out for future deletion
    # test "seek reverts to original position on exit":
    #   var codeStream = newCodeStream("\x01\x02\x30")
    #   check(codeStream.pc == 0)
    #   codeStream.seek(1):
    #     check(codeStream.pc == 1)
    #     check(codeStream.next == Op.MUL)
    #   check(codeStream.pc == 0)
    #   check(codeStream.peek == Op.ADD)

    test "[] returns opcode":
      let codeStream = newCodeStream("\x01\x02\x30")
      check(codeStream[0] == Op.ADD)
      check(codeStream[1] == Op.MUL)
      check(codeStream[2] == Op.ADDRESS)

    test "isValidOpcode invalidates after PUSHXX":
      var codeStream = newCodeStream("\x02\x60\x02\x04")
      check(codeStream.isValidOpcode(0))
      check(codeStream.isValidOpcode(1))
      check(not codeStream.isValidOpcode(2))
      check(codeStream.isValidOpcode(3))
      check(not codeStream.isValidOpcode(4))


    test "isValidOpcode 0":
      var codeStream = newCodeStream(@[2.byte, 3.byte, 0x72.byte].concat(repeat(4.byte, 32)).concat(@[5.byte]))
      # valid: 0 - 2 :: 22 - 35
      # invalid: 3-21 (PUSH19) :: 36+ (too long)
      check(codeStream.isValidOpcode(0))
      check(codeStream.isValidOpcode(1))
      check(codeStream.isValidOpcode(2))
      check(not codeStream.isValidOpcode(3))
      check(not codeStream.isValidOpcode(21))
      check(codeStream.isValidOpcode(22))
      check(codeStream.isValidOpcode(35))
      check(not codeStream.isValidOpcode(36))


    test "isValidOpcode 1":
      let test = @[2.byte, 3.byte, 0x7d.byte].concat(repeat(4.byte, 32)).concat(@[5.byte, 0x7e.byte]).concat(repeat(4.byte, 35)).concat(@[1.byte, 0x61.byte, 1.byte, 1.byte, 1.byte])
      var codeStream = newCodeStream(test)
      # valid: 0 - 2 :: 33 - 36 :: 68 - 73 :: 76
      # invalid: 3 - 32 (PUSH30) :: 37 - 67 (PUSH31) :: 74, 75 (PUSH2) :: 77+ (too long)
      check(codeStream.isValidOpcode(0))
      check(codeStream.isValidOpcode(1))
      check(codeStream.isValidOpcode(2))
      check(not codeStream.isValidOpcode(3))
      check(not codeStream.isValidOpcode(32))
      check(codeStream.isValidOpcode(33))
      check(codeStream.isValidOpcode(36))
      check(not codeStream.isValidOpcode(37))
      check(not codeStream.isValidOpcode(67))
      check(codeStream.isValidOpcode(68))
      check(codeStream.isValidOpcode(71))
      check(codeStream.isValidOpcode(72))
      check(codeStream.isValidOpcode(73))
      check(not codeStream.isValidOpcode(74))
      check(not codeStream.isValidOpcode(75))
      check(codeStream.isValidOpcode(76))
      check(not codeStream.isValidOpcode(77))


    test "right number of bytes invalidates":
      var codeStream = newCodeStream("\x02\x03\x60\x02\x02")
      check(codeStream.isValidOpcode(0))
      check(codeStream.isValidOpcode(1))
      check(codeStream.isValidOpcode(2))
      check(not codeStream.isValidOpcode(3))
      check(codeStream.isValidOpcode(4))
      check(not codeStream.isValidOpcode(5))

  suite "EOF decode":
    type
      EOFVector = object
        name: string
        data: string
        err : EOFV1ErrorKind

    proc ev(name: string, data: string, err: EOFV1ErrorKind): EOFVector =
      EOFVector(name: name, data: data, err: err)

    const EOFVectors = [
      ev("no magic", "", ErrUnexpectedEOF),
      ev("bad magic 1", "EF", ErrUnexpectedEOF),
      ev("bad magic 2", "EF11", ErrInvalidMagic),
      ev("bad version 1", "EF00", ErrInvalidVersion),
      ev("bad version 2", "EF0033", ErrInvalidVersion),
      ev("bad version 3", "EF0033", ErrInvalidVersion),
      ev("no type section 1", "EF0001", ErrUnexpectedEOF),
      ev("bad type section 2", "EF0001020000", ErrMissingTypeHeader),
      ev("bad type section 3", "EF0001010000", ErrInvalidTypeSize),
      ev("bad type section 4", "EF000101", ErrUnexpectedEOF),
      ev("bad type section 5", "EF000101FFFC", ErrInvalidTypeSize),
      ev("no code section", "EF0001010004", ErrUnexpectedEOF),
      ev("bad code section", "EF000101000402000200010001", ErrInvalidCodeSize),
      ev("no data section", "EF00010100040200010001", ErrUnexpectedEOF),
      ev("bad data section", "EF00010100040200010001040001", ErrMissingDataHeader),
      ev("no terminator", "EF00010100040200010001030001", ErrUnexpectedEOF),
      ev("bad size", "EF0001010004020001000103000100", ErrInvalidContainerSize),
    ]

    var c: Container
    template parseERR(x: string, k: EOFV1ErrorKind) =
      let res = c.decode(hexToSeqByte(x))
      check res.isErr
      check res.error.kind == k

    template parseOK(x: string) =
      let res = c.decode(hexToSeqByte(x))
      check res.isOK

    for x in EOFVectors:
      test x.name:
        parseERR(x.data, x.err)

    test "parse ok":
      parseOK("EF000101000402000100010300010000000001BBAA")
      check c.code[0].len == 1
      check c.code[0][0] == 0xBB.byte
      check c.data.len == 1
      check c.data[0] == 0xAA.byte

  suite "code analysis":
    type
      Spec = object
        code : seq[byte]
        exp  : byte
        which: int

    proc spec(code: openArray[byte], exp: byte, which: int): Spec =
      Spec(code: @code, exp: exp, which: which)

    const vectors = [
      spec(@[byte(PUSH1), 0x01, 0x01, 0x01], 0b0000_0010, 0),
      spec(@[byte(PUSH1), byte(PUSH1), byte(PUSH1), byte(PUSH1)], 0b0000_1010, 0),
      spec(@[byte(0x00), byte(PUSH1), 0x00, byte(PUSH1), 0x00, byte(PUSH1), 0x00, byte(PUSH1)], 0b0101_0100, 0),
      spec(@[byte(PUSH8), byte(PUSH8), byte(PUSH8), byte(PUSH8), byte(PUSH8),
        byte(PUSH8), byte(PUSH8), byte(PUSH8), 0x01, 0x01, 0x01], 0xFE, 0),
      spec(@[byte(PUSH8), 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01], 0b0000_0001, 1),
      spec(@[byte(0x01), 0x01, 0x01, 0x01, 0x01, byte(PUSH2), byte(PUSH2), byte(PUSH2), 0x01, 0x01, 0x01], 0b1100_0000, 0),
      spec(@[byte(0x01), 0x01, 0x01, 0x01, 0x01, byte(PUSH2), 0x01, 0x01, 0x01, 0x01, 0x01], 0b0000_0000, 1),
      spec(@[byte(PUSH3), 0x01, 0x01, 0x01, byte(PUSH1), 0x01, 0x01, 0x01, 0x01, 0x01, 0x01], 0b0010_1110, 0),
      spec(@[byte(PUSH3), 0x01, 0x01, 0x01, byte(PUSH1), 0x01, 0x01, 0x01, 0x01, 0x01, 0x01], 0b0000_0000, 1),
      spec(@[byte(0x01), byte(PUSH8), 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01], 0b1111_1100, 0),
      spec(@[byte(0x01), byte(PUSH8), 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01], 0b0000_0011, 1),
      spec(@[byte(PUSH16), 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01], 0b1111_1110, 0),
      spec(@[byte(PUSH16), 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01], 0b1111_1111, 1),
      spec(@[byte(PUSH16), 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01], 0b0000_0001, 2),
      spec(@[byte(PUSH8), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, byte(PUSH1), 0x01], 0b1111_1110, 0),
      spec(@[byte(PUSH8), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, byte(PUSH1), 0x01], 0b0000_0101, 1),
      spec(@[byte(PUSH32)], 0b1111_1110, 0),
      spec(@[byte(PUSH32)], 0b1111_1111, 1),
      spec(@[byte(PUSH32)], 0b1111_1111, 2),
      spec(@[byte(PUSH32)], 0b1111_1111, 3),
      spec(@[byte(PUSH32)], 0b0000_0001, 4),
    ]

    const eofVectors = [
      spec(@[byte(RJUMP), 0x01, 0x01, 0x01], 0b0000_0110, 0),
      spec(@[byte(RJUMPI), byte(RJUMP), byte(RJUMP), byte(RJUMPI)], 0b0011_0110, 0),
      spec(@[byte(RJUMPV), 0x02, byte(RJUMP), 0x00, byte(RJUMPI), 0x00], 0b0011_1110, 0),
    ]

    test "jump dest analysis":
      for x in vectors:
        let z = codeBitmap(x.code)
        check z[x.which] == x.exp
        let y = eofCodeBitmap(x.code)
        check y[x.which] == x.exp

    test "eof analysis":
      for x in eofVectors:
        let z = eofCodeBitmap(x.code)
        check z[x.which] == x.exp

  suite "validate code tests":
    type
      ValidateVector = object
        code: seq[byte]
        section: int
        metadata: seq[FunctionMetadata]
        err: EOFV1ErrorKind

    proc vv(code: openArray[byte], section: int,
            met: openArray[FunctionMetaData],
            err = ErrNoEOFErr): ValidateVector =
      ValidateVector(code: @code, section: section,
        metadata: @met, err: err)

    proc fm(input, output, max: int): FunctionMetadata =
      FunctionMetadata(input: input.uint8,
        output: output.uint8, maxStackHeight: max.uint16)

    const
      ValidateVectors = [
        vv([byte(CALLER), byte(POP), byte(STOP)], 0, [fm(0, 0, 1)]),

        vv([byte(CALLF), 0x00, 0x00, byte(STOP)], 0, [fm(0, 0, 0)]),

        vv([
          byte(ADDRESS), byte(CALLF), 0x00, 0x00, byte(STOP)], 0,
        [fm(0, 0, 1)]),

        vv([byte(CALLER), byte(POP),], 0,
        [fm(0, 0, 1)],
        ErrInvalidCodeTermination),

        vv([
          byte(RJUMP),
          byte(0x00),
          byte(0x01),
          byte(CALLER),
          byte(STOP)], 0,
        [fm(0, 0, 0)],
        ErrUnreachableCode),

        vv([
          byte(PUSH1), byte(0x42), byte(ADD), byte(STOP)], 0,
        [fm(0, 0, 1)],
        ErrStackUnderflow),

        vv([
          byte(PUSH1), byte(0x42), byte(POP), byte(STOP)], 0,
        [fm(0, 0, 2)],
        ErrInvalidMaxStackHeight),

        vv([
          byte(PUSH0),
          byte(RJUMPI),
          byte(0x00),
          byte(0x01),
          byte(PUSH1),
          byte(0x42), # jumps to here
          byte(POP),
          byte(STOP)], 0,
        [fm(0, 0, 1)],
        ErrInvalidJumpDest),

        vv([
          byte(PUSH0),
          byte(RJUMPV),
          byte(0x02),
          byte(0x00),
          byte(0x01),
          byte(0x00),
          byte(0x02),
          byte(PUSH1),
          byte(0x42), # jumps to here
          byte(POP),  # and here
          byte(STOP)], 0,
        [fm(0, 0, 1)],
        ErrInvalidJumpDest),

        vv([
          byte(PUSH0), byte(RJUMPV), byte(0x00), byte(STOP)], 0,
        [fm(0, 0, 1)],
        ErrInvalidBranchCount),

        vv([
          byte(RJUMP), 0x00, 0x03,
          byte(JUMPDEST),
          byte(JUMPDEST),
          byte(RETURN),
          byte(PUSH1), 20,
          byte(PUSH1), 39,
          byte(PUSH1), 0x00,
          byte(CODECOPY),
          byte(PUSH1), 20,
          byte(PUSH1), 0x00,
          byte(RJUMP), 0xff, 0xef], 0,
        [fm(0, 0, 3)]),

        vv([
          byte(PUSH1), 1,
          byte(RJUMPI), 0x00, 0x03,
          byte(JUMPDEST),
          byte(JUMPDEST),
          byte(STOP),
          byte(PUSH1), 20,
          byte(PUSH1), 39,
          byte(PUSH1), 0x00,
          byte(CODECOPY),
          byte(PUSH1), 20,
          byte(PUSH1), 0x00,
          byte(RETURN)], 0,
        [fm(0, 0, 3)]),

        vv([
          byte(PUSH1), 1,
          byte(RJUMPV), 0x02, 0x00, 0x03, 0xff, 0xf8,
          byte(JUMPDEST),
          byte(JUMPDEST),
          byte(STOP),
          byte(PUSH1), 20,
          byte(PUSH1), 39,
          byte(PUSH1), 0x00,
          byte(CODECOPY),
          byte(PUSH1), 20,
          byte(PUSH1), 0x00,
          byte(RETURN)], 0,
        [fm(0, 0, 3)]),

        vv([byte(STOP), byte(STOP), byte(INVALID)], 0,
        [fm(0, 0, 0)],
        ErrUnreachableCode),

        vv([byte(RETF)], 0, [fm(0, 1, 0)], ErrInvalidOutputs),

        vv([byte(RETF)], 0, [fm(3, 3, 3)]),

        vv([byte(CALLF), 0x00, 0x01, byte(POP), byte(STOP)], 0,
        [fm(0, 0, 1), fm(0, 1, 0)]),

        vv([
          byte(ORIGIN),
          byte(ORIGIN),
          byte(CALLF), 0x00, 0x01,
          byte(POP),
          byte(RETF)], 0,
        [fm(0, 0, 2), fm(2, 1, 2)]),
      ]

    for i, x in ValidateVectors:
      test "validate code " & $i:
        let res = validateCode(x.code, x.section, x.metadata)
        if res.isErr:
          check res.error.kind == x.err
        else:
          check x.err == ErrNoEOFErr

when isMainModule:
  codeStreamMain()
