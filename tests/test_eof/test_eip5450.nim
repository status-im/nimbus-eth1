# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

from eip5450 import validate_function, FunctionType, ValidationException
from eip5450_table import *
import pytest


def test_empty():
    assert validate_function(0, bytes((OP_STOP,))) == 0


def test_stack_empty_at_exit():
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(0, bytes((OP_NUMBER, OP_STOP)))
    assert validate_function(0, bytes((OP_NUMBER, OP_POP, OP_STOP))) == 1
    assert validate_function(1, bytes((OP_POP, OP_STOP)), [FunctionType(0, 0), FunctionType(1, 0)]) == 1
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(1, bytes((OP_STOP,)), [FunctionType(0, 0), FunctionType(1, 0)])


def test_immediate_bytes():
    assert validate_function(0, bytes((OP_PUSH1, 0x01, OP_POP, OP_STOP))) == 1


def test_stack_underflow():
    with pytest.raises(ValidationException, match="stack underflow"):
        validate_function(0, bytes((OP_POP, OP_STOP)))


def test_jump_forward():
    assert validate_function(0, bytes((OP_RJUMP, 0x00, 0x00, OP_STOP))) == 0
    assert validate_function(0, bytes((OP_RJUMP, 0x00, 0x01, OP_NUMBER, OP_STOP))) == 0
    assert validate_function(0, bytes((OP_RJUMP, 0x00, 0x02, OP_NUMBER, OP_POP, OP_STOP))) == 0
    assert validate_function(0, bytes((OP_RJUMP, 0x00, 0x03, OP_ADD, OP_POP, OP_STOP, OP_PUSH1, 0x01, OP_PUSH1, 0x01, OP_RJUMP, 0xff, 0xf6, OP_STOP))) == 2


def test_jump_backwards():
    assert validate_function(0, bytes((OP_RJUMP, 0xff, 0xfd, OP_STOP))) == 0
    assert validate_function(0, bytes((OP_JUMPDEST, OP_RJUMP, 0xff, 0xfc, OP_STOP))) == 0
    with pytest.raises(ValidationException, match="stack height mismatch for different paths"):
        validate_function(0, bytes((OP_NUMBER, OP_RJUMP, 0xff, 0xfc, OP_POP, OP_STOP)))
    with pytest.raises(ValidationException, match="stack height mismatch for different paths"):
        validate_function(0, bytes((OP_NUMBER, OP_POP, OP_RJUMP, 0xff, 0xfc, OP_STOP)))
    assert validate_function(0, bytes((OP_NUMBER, OP_POP, OP_RJUMP, 0xff, 0xfd, OP_STOP))) == 1
    assert validate_function(0, bytes((OP_NUMBER, OP_POP, OP_JUMPDEST, OP_RJUMP, 0xff, 0xfc, OP_STOP))) == 1
    assert validate_function(0, bytes((OP_NUMBER, OP_POP, OP_NUMBER, OP_RJUMP, 0xff, 0xfb, OP_POP, OP_STOP))) == 1
    with pytest.raises(ValidationException, match="stack height mismatch for different paths"):
        validate_function(0, bytes((OP_NUMBER, OP_POP, OP_NUMBER, OP_RJUMP, 0xff, 0xfc, OP_POP, OP_STOP)))

def test_conditional_jump():
    # Each branch ending with STOP
    assert validate_function(0, bytes((OP_PUSH1, 0xff, OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x02, OP_POP, OP_STOP, OP_POP, OP_STOP))) == 2
    # One branch ending with RJUMP
    assert validate_function(0, bytes((OP_PUSH1, 0xff, OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x04, OP_POP, OP_RJUMP, 0x00, 0x01, OP_POP, OP_STOP))) == 2
    # Fallthrough
    assert validate_function(0, bytes((OP_PUSH1, 0xff, OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x04, OP_DUP1, OP_DUP1, OP_POP, OP_POP, OP_POP, OP_STOP))) == 3
    # Offset 0
    assert validate_function(0, bytes((OP_PUSH1, 0xff, OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x00, OP_POP, OP_STOP))) == 2
    # Simple loop (RJUMP offset = -5)
    assert validate_function(0, bytes((OP_PUSH1, 0x01, OP_PUSH1, 0xff, OP_DUP2, OP_SUB, OP_DUP1, OP_RJUMPI, 0xff, 0xfa, OP_POP, OP_POP, OP_STOP))) == 3
    # One branch increasing max stack more stack than another
    assert validate_function(0, bytes((OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x07, OP_ADDRESS, OP_ADDRESS, OP_ADDRESS, OP_POP, OP_POP, OP_POP, OP_STOP, OP_ADDRESS, OP_POP, OP_STOP))) == 3
    assert validate_function(0, bytes((OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x03, OP_ADDRESS, OP_POP, OP_STOP, OP_ADDRESS, OP_ADDRESS, OP_ADDRESS, OP_POP, OP_POP, OP_POP, OP_STOP))) == 3

    # Missing stack argument
    with pytest.raises(ValidationException, match="stack underflow"):
        validate_function(0, bytes((OP_RJUMPI, 0x00, 0x00, OP_STOP)))
    # Stack underflow in one branch
    with pytest.raises(ValidationException, match="stack underflow"):
        validate_function(0, bytes((OP_PUSH1, 0xff, OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x02, OP_POP, OP_STOP, OP_SUB, OP_POP, OP_STOP)))
    with pytest.raises(ValidationException, match="stack underflow"):
        validate_function(0, bytes((OP_PUSH1, 0xff, OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x02, OP_SUB, OP_STOP, OP_NOT, OP_POP, OP_STOP)))
    # Stack not empty in the end of one branch
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(0, bytes((OP_PUSH1, 0xff, OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x02, OP_POP, OP_STOP, OP_NOT, OP_STOP)))
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(0, bytes((OP_PUSH1, 0xff, OP_PUSH1, 0x01, OP_RJUMPI, 0x00, 0x02, OP_NOT, OP_STOP, OP_POP, OP_STOP)))

def test_callf():
    # 0 inputs, 0 outpus
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x01, OP_STOP)), [FunctionType(0, 0), FunctionType(0, 0)]) == 0
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x02, OP_STOP)), [FunctionType(0, 0), FunctionType(1, 1), FunctionType(0, 0)]) == 0

    # more than 0 inputs
    assert validate_function(0, bytes((OP_ADDRESS, OP_CALLF, 0x00, 0x01, OP_STOP)), [FunctionType(0, 0), FunctionType(1, 0)]) == 1
    # forwarding an argument
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x01, OP_STOP)), [FunctionType(1, 0), FunctionType(1, 0)]) == 1

    # more than 1 inputs
    assert validate_function(0, bytes((OP_ADDRESS, OP_DUP1, OP_CALLF, 0x00, 0x01, OP_STOP)), [FunctionType(0, 0), FunctionType(2, 0)]) == 2

    # more than 0 outputs
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x01, OP_POP, OP_STOP)), [FunctionType(0, 0), FunctionType(0, 1)]) == 1
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x02, OP_POP, OP_STOP)), [FunctionType(0, 0), FunctionType(0, 0), FunctionType(0, 1)]) == 1

    # more than 1 outputs
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x01, OP_POP, OP_POP, OP_STOP)), [FunctionType(0, 0), FunctionType(0, 2)]) == 2

    # more than 0 inputs, more than 0 outputs
    assert validate_function(0, bytes((OP_ADDRESS, OP_ADDRESS, OP_CALLF, 0x00, 0x01, OP_POP, OP_POP, OP_POP, OP_STOP)), [FunctionType(0, 0), FunctionType(2, 3)]) == 3

    # recursion
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x00, OP_STOP)), [FunctionType(0, 0)]) == 0
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x00, OP_STOP)), [FunctionType(2, 0)]) == 2
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x00, OP_POP, OP_POP, OP_STOP)), [FunctionType(2, 2)]) == 2
    assert validate_function(1, bytes((OP_ADDRESS, OP_ADDRESS, OP_CALLF, 0x00, 0x01, OP_POP, OP_POP, OP_POP, OP_STOP)), [FunctionType(0, 0), FunctionType(2, 1)]) == 4

    # multiple CALLFs with different types
    assert validate_function(0, bytes((OP_PREVRANDAO, OP_CALLF, 0x00, 0x01, OP_DUP1, OP_DUP1, OP_CALLF, 0x00, 0x02,
        OP_PREVRANDAO, OP_DUP1, OP_CALLF, 0x00, 0x03, OP_POP, OP_POP, OP_STOP)), [FunctionType(0, 0), FunctionType(1, 1), FunctionType(3, 0), FunctionType(2, 2)]) == 3

    # underflow
    with pytest.raises(ValidationException, match="stack underflow"):
        validate_function(0, bytes((OP_CALLF, 0x00, 0x01, OP_STOP)), [FunctionType(0, 0), FunctionType(1, 0)])
    with pytest.raises(ValidationException, match="stack underflow"):
        validate_function(0, bytes((OP_ADDRESS, OP_CALLF, 0x00, 0x01, OP_STOP)), [FunctionType(0, 0), FunctionType(2, 0)])
    with pytest.raises(ValidationException, match="stack underflow"):
        validate_function(0, bytes((OP_POP, OP_CALLF, 0x00, 0x00, OP_STOP)), [FunctionType(1, 0)])
    with pytest.raises(ValidationException, match="stack underflow"):
        validate_function(0, bytes((OP_PREVRANDAO, OP_CALLF, 0x00, 0x01, OP_DUP1, OP_CALLF, 0x00, 0x02, OP_STOP)),
            [FunctionType(0, 0), FunctionType(1, 1), FunctionType(3, 0)])

def test_retf():
    # 0 outpus
    assert validate_function(0, bytes((OP_RETF,)), [FunctionType(0, 0), FunctionType(0, 0)]) == 0
    assert validate_function(1, bytes((OP_RETF,)), [FunctionType(0, 0), FunctionType(0, 0)]) == 0
    assert validate_function(2, bytes((OP_RETF,)), [FunctionType(0, 0), FunctionType(1, 1), FunctionType(0, 0)]) == 0

    # more than 0 outputs
    assert validate_function(0, bytes((OP_PREVRANDAO, OP_RETF)), [FunctionType(0, 1), FunctionType(0, 1)]) == 1
    assert validate_function(1, bytes((OP_PREVRANDAO, OP_RETF)), [FunctionType(0, 1), FunctionType(0, 1)]) == 1

    # more than 1 outputs
    assert validate_function(1, bytes((OP_PREVRANDAO, OP_DUP1, OP_RETF)), [FunctionType(0, 0), FunctionType(0, 2)]) == 2

    # forwarding return value
    assert validate_function(0, bytes((OP_RETF,)), [FunctionType(1, 1)]) == 1
    assert validate_function(0, bytes((OP_CALLF, 0x00, 0x01, OP_RETF)), [FunctionType(0, 1), FunctionType(0, 1)]) == 1

    # multiple RETFs
    assert validate_function(0, bytes((OP_RJUMPI, 0x00, 0x03, OP_PREVRANDAO, OP_DUP1, OP_RETF, OP_ADDRESS, OP_DUP1, OP_RETF)), [FunctionType(1, 2)]) == 2

    # underflow
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(0, bytes((OP_RETF,)), [FunctionType(0, 1), FunctionType(0, 1)])
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(1, bytes((OP_RETF,)), [FunctionType(0, 1), FunctionType(0, 1)])
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(0, bytes((OP_RETF,)), [FunctionType(0, 1)])
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(1, bytes((OP_PREVRANDAO, OP_RETF)), [FunctionType(0, 0), FunctionType(0, 2)])
    with pytest.raises(ValidationException, match="non-empty stack on terminating instruction"):
        validate_function(0, bytes((OP_RJUMPI, 0x00, 0x03, OP_PREVRANDAO, OP_DUP1, OP_RETF, OP_ADDRESS, OP_RETF)), [FunctionType(1, 2)])


def test_unreachable():
    # Max stack not changed by unreachable code
    assert validate_function(0, bytes((OP_ADDRESS, OP_POP, OP_STOP, OP_ADDRESS, OP_ADDRESS, OP_ADDRESS, OP_POP, OP_POP, OP_POP, OP_STOP))) == 1
    assert validate_function(0, bytes((OP_ADDRESS, OP_POP, OP_RETF, OP_ADDRESS, OP_ADDRESS, OP_ADDRESS, OP_POP, OP_POP, OP_POP, OP_STOP))) == 1
    assert validate_function(0, bytes((OP_ADDRESS, OP_POP, OP_RJUMP, 0x00, 0x06, OP_ADDRESS, OP_ADDRESS, OP_ADDRESS, OP_POP, OP_POP, OP_POP, OP_STOP))) == 1
    # Stack underflow in unreachable code
    assert validate_function(0, bytes((OP_ADDRESS, OP_POP, OP_STOP, OP_POP, OP_STOP))) == 1
    assert validate_function(0, bytes((OP_ADDRESS, OP_POP, OP_RETF, OP_POP, OP_STOP))) == 1
    assert validate_function(0, bytes((OP_ADDRESS, OP_POP, OP_RJUMP, 0x00, 0x01, OP_POP, OP_STOP))) == 1

def test_stack_overflow():
    assert validate_function(0, bytes([OP_NUMBER] * 1022 + [OP_POP] * 1022 + [OP_STOP])) == 1022
    with pytest.raises(ValidationException, match="max stack above limit"):
        validate_function(0, bytes([OP_NUMBER] * 1023 + [OP_POP] * 1023 + [OP_STOP]))
