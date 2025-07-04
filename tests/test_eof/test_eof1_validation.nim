# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

from eof1_validation import *
import pytest


def is_valid_eof(code: bytes) -> bool:
    try:
        validate_eof1(code)
    except ValidationException:
        return False
    return True


def is_invalid_eof_with_error(code: bytes, error: str):
    with pytest.raises(ValidationException, match=error):
        validate_eof1(code)


def test_read_eof1_header():
    # Code and data section
    assert read_eof1_header(bytes.fromhex('ef000101000102000100feaa')) \
           == EOF([FunctionType(0, 0)], [bytes.fromhex('fe')])

    # Valid with one code section and implicit type section
    assert read_eof1_header(bytes.fromhex('ef0001 010001 00 fe')) \
           == EOF([FunctionType(0, 0)], [bytes.fromhex('fe')])

    # Valid with one code section and explicit type section
    assert read_eof1_header(bytes.fromhex('ef0001 030002 010001 00 0000 fe')) \
           == EOF([FunctionType(0, 0)], [bytes.fromhex('fe')])

    # Valid with two code sections, 2nd code sections has 0 inputs and 1 output
    assert read_eof1_header(bytes.fromhex('ef0001 030004 010001 010003 00 00000001 fe 6000fc')) \
           == EOF([FunctionType(0, 0), FunctionType(0, 1)], [bytes.fromhex('fe'), bytes.fromhex('6000fc')])

    # Valid with two code sections, 2nd code sections has 2 inputs and 0 outputs
    assert read_eof1_header(bytes.fromhex('ef0001 030004 010001 010003 00 00000200 fe 5050fc')) \
           == EOF([FunctionType(0, 0), FunctionType(2, 0)], [bytes.fromhex('fe'), bytes.fromhex('5050fc')])

    # Valid with two code sections, 2nd code sections has 2 inputs and 1 output
    assert read_eof1_header(bytes.fromhex('ef0001 030004 010001 010002 00 00000201 fe 50fc')) \
           == EOF([FunctionType(0, 0), FunctionType(2, 1)], [bytes.fromhex('fe'), bytes.fromhex('50fc')])

    # Valid with two code sections and one data section
    assert read_eof1_header(bytes.fromhex('ef0001 030004 010001 010002 020004 00 00000201 fe 50fc aabbccdd')) \
           == EOF([FunctionType(0, 0), FunctionType(2, 1)], [bytes.fromhex('fe'), bytes.fromhex('50fc')])


def test_valid_eof1_container():
    # Single code section
    assert is_valid_eof(bytes.fromhex("ef000101000100fe"))
    # Code section and data section
    assert is_valid_eof(bytes.fromhex("ef000101000102000100feaa"))
    # Type section and two code sections
    assert is_valid_eof(bytes.fromhex("ef0001 030004 010001 010003 00 00000001 fe 6000b1"))
    # Type section, two code sections, data section
    assert is_valid_eof(bytes.fromhex("ef0001 030004 010001 010002 020004 00 00000201 fe 50b1 aabbccdd"))

    # Example with 3 functions
    assert is_valid_eof(bytes.fromhex("ef0001 030006 01003b 010017 01001d 00 000001010101 "
                                      "60043560e06000351c639b0890d581145d001c6320cb776181145d00065050600080fd50b0000260005260206000f350b0000160005260206000f3"
                                      "600181115d0004506001b160018103b0000281029050b1 600281115d0004506001b160028103b0000160018203b00001019050b1"))


def test_invalid_eof1_container():
    # EIP-3540 violation - malformed container
    is_invalid_eof_with_error(bytes.fromhex("ef0001 010001 020002 00 fe aa"), "container size not equal to sum of section sizes")
    # EIP-3670 violation - undefined opcode
    is_invalid_eof_with_error(bytes.fromhex("ef0001 010002 00 f600"), "undefined instruction")
    # EIP-4200 violation - invalid RJUMP
    is_invalid_eof_with_error(bytes.fromhex("ef0001 010004 00 5c00ff00"), "relative jump destination out of bounds")
    # EIP-4750 violation - invalid CALLF
    is_invalid_eof_with_error(bytes.fromhex("ef0001 030004 010005 010003 00 00000001 b0ffff5000 6000b1"), "invalid section id")
    # EIP-5450 violation - stack underflow
    is_invalid_eof_with_error(bytes.fromhex("ef0001 030004 010005 010004 00 00000001 b000015000 600001b1"), "stack underflow")