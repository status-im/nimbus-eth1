# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

# Don't use this for production code!
# Starting from bal@v5.6.0, some of the path and file name
# exceeds MAX_PATH length on Windows
when defined(windows):
  import
    std/[os, strutils]

  const
    baseFolder = currentSourcePath.rsplit({DirSep, AltSep}, 3)[0]
    prefix = "\\\\?\\" & baseFolder

  template handleLongPath*(x: string): string =
    prefix / x

else:
  template handleLongPath*(x: string): string =
    x
