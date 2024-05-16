# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/os,
  eth/common,
  "."/[undump_blocks_era1, undump_blocks_gz]

# ------------------------------------------------------------------------------
# Public undump
# ------------------------------------------------------------------------------

iterator undumpBlocks*(file: string): (seq[BlockHeader],seq[BlockBody]) =
  let ext = file.splitFile.ext
  if ext == ".era1":
    for w in file.undumpBlocksEra1:
      yield w
  elif ext == ".gz":
    for w in file.undumpBlocksGz:
      yield w
  else:
    raiseAssert "Unsupported extension for \"" &
      file & "\" (got \"" & ext & "\")"

iterator undumpBlocks*(files: seq[string]): (seq[BlockHeader],seq[BlockBody]) =
  for f in files:
    for w in f.undumpBlocks:
      yield w

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
