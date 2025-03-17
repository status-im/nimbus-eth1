# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

from dataclasses import dataclass

from eip4750 import *
from eip5450 import validate_function, FunctionType


@dataclass



# EOF code validation, including container format validation, code section validation and function stack validation.
# Raises ValidationException on invalid code
func validate_eof1(container: bytes):
  validate_eof(container)
  eof = read_eof1_header(container)
  for func_idx, code in enumerate(eof.codes):
    validate_function(func_idx, code, eof.types)


func read_eof1_header(container: bytes) -> EOF:
  section_sizes = {S_TYPE: [], S_CODE: [], S_DATA: []}
  pos = len(MAGIC) + 1
  while true:
    section_id = container[pos]
    pos += 1
    if section_id == S_TERMINATOR:
      break

    section_sizes[section_id].append((container[pos] << 8) | container[pos + 1])
    pos += 2

  if len(section_sizes[S_TYPE]) != 0:
    type_section_size = section_sizes[S_TYPE][0]
    types = read_eof1_types(container, pos, type_section_size)
    pos += type_section_size
  else:
    types = [FunctionType(0, 0)]  # implicit code section 0 type

  eof = EOF(types, [])
  for code_size in section_sizes[S_CODE]:
    eof.codes.append(container[pos:pos + code_size])
    pos += code_size

  return eof


func read_eof1_types(container: bytes, header_size: int, type_section_size: int) -> list[FunctionType]:
  pos = header_size
  types = []
  while pos < header_size + type_section_size:
    types.append(FunctionType(container[pos], container[pos + 1]))
    pos += 2

  return types