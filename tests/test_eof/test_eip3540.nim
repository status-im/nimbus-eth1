# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

from eip3540 import is_valid_container, validate_eof, ValidationException
import pytest

def is_invalid_with_error(code: bytes, error: str):
    with pytest.raises(ValidationException, match=error):
        validate_eof(code)

def test_legacy_contracts():
    assert is_valid_container(b'') == True
    assert is_valid_container(bytes.fromhex('00')) == True
    assert is_valid_container(bytes.fromhex('ef')) == True  # Magic second byte missing

def test_no_eof_magic():
    # Any value outside the magic second byte
    for m in range(1, 256):
        assert is_valid_container(bytes((0xEF, m))) == True

def test_eof1_container():
    is_invalid_with_error(bytes.fromhex('ef00'), "invalid version")
    is_invalid_with_error(bytes.fromhex('ef0001'), "no section terminator")
    is_invalid_with_error(bytes.fromhex('ef0000'), "invalid version")
    is_invalid_with_error(bytes.fromhex('ef0002 010001 00 fe'), "invalid version") # Valid except version
    is_invalid_with_error(bytes.fromhex('ef0001 00'), "no code section") # Only terminator
    is_invalid_with_error(bytes.fromhex('ef0001 010001 00 fe aabbccdd'), "container size not equal to sum of section sizes") # Trailing bytes
    is_invalid_with_error(bytes.fromhex('ef000101'), "truncated section size")
    is_invalid_with_error(bytes.fromhex('ef000101000102'), "truncated section size")
    is_invalid_with_error(bytes.fromhex('ef000103'), "invalid section id")
    is_invalid_with_error(bytes.fromhex('ef00010100'), "truncated section size")
    is_invalid_with_error(bytes.fromhex('ef00010100010200'), "truncated section size")
    is_invalid_with_error(bytes.fromhex('ef000101000000'), "empty section")
    is_invalid_with_error(bytes.fromhex('ef000101000102000000fe'), "empty section")
    is_invalid_with_error(bytes.fromhex('ef0001010001'), "no section terminator")
    is_invalid_with_error(bytes.fromhex('ef000101000100'), "container size not equal to sum of section sizes") # Missing section contents
    is_invalid_with_error(bytes.fromhex('ef000102000100aa'), "data section preceding code section") # Only data section
    is_invalid_with_error(bytes.fromhex('ef000101000101000100fefe'), "multiple sections with same id") # Multiple code sections
    is_invalid_with_error(bytes.fromhex('ef000101000102000102000100feaabb'), "multiple sections with same id") # Multiple data sections
    is_invalid_with_error(bytes.fromhex('ef000101000101000102000102000100fefeaabb'), "multiple sections with same id")# Multiple code and data sections
    is_invalid_with_error(bytes.fromhex('ef000102000101000100aafe'), "data section preceding code section")

    assert is_valid_container(bytes.fromhex('ef000101000100fe')) == True  # Valid format with 1-byte of code
    assert is_valid_container(bytes.fromhex('ef000101000102000100feaa')) == True  # Code and data section