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

iterator undumpBlocks*(
    file: string;
    least = low(uint64);                     # First block to extract
    stopAfter = high(uint64);                # Last block to extract
      ): (seq[BlockHeader],seq[BlockBody]) =
  if file.dirExists:
    for w in file.undumpBlocksEra1(least, stopAfter):
      yield w
  else:
    let ext = file.splitFile.ext
    if ext == ".gz":
      for w in file.undumpBlocksGz(least, stopAfter):
        yield w
    else:
      raiseAssert "Unsupported extension for \"" &
        file & "\" (got \"" & ext & "\")"

iterator undumpBlocks*(
    files: seq[string];
    least = low(uint64);                     # First block to extract
    stopAfter = high(uint64);                # Last block to extract
      ): (seq[BlockHeader],seq[BlockBody]) =
  for f in files:
    for w in f.undumpBlocks(least, stopAfter):
      yield w

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
