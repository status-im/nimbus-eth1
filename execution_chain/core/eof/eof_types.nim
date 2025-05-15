# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

type
  CodeView* = ptr UncheckedArray[byte]

  EOFHeader* = object
    typesSize*: int
    codeSizes*: seq[int]
    containerSizes*: seq[int]
    dataSize*: int

  EOFType* = object
    inputs* : uint8
    outputs*: uint8
    maxStackIncrease*: uint16
    
  EOFBody* = object
    types*: seq[EOFType]
    codes*: seq[CodeView]
    containers*: seq[CodeView]
    data*: CodeView
    
func size*(h: EOFHeader): int =
  # 3 bytes = magic, version
  # 3 bytes = kind_types, types_size
  # 3 + 2n  = kind_code, num_code_sections, code_size+
  # 3 + 2n  = kind_container, num_container_sections, container_size+
  # 4 bytes = kind_data, data_size, terminator
  if h.containerSizes.len > 0:
    3 + 3 + 3 + h.codeSizes.len*2 + 3 + h.containerSizes.len*2 + 4
  else:
    3 + 3 + 3 + h.codeSizes.len*2 + 4
