# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

#------------------------------------------------------------------------------
# The only place where NimbusVersion is declared.
# Please do not put nim vm unfriendly stuff in this file, otherwise it will
# break some scripts. Users of this file:
# - ./version_info.nim > used by compiled binaries.
# - ../scripts/print_version.nims > used by docker files.
#------------------------------------------------------------------------------

const
  NimbusMajor* = 0
  ## is the major number of Nimbus' version.

  NimbusMinor* = 2
  ## is the minor number of Nimbus' version.

  NimbusPatch* = 2
  ## is the patch number of Nimbus' version.

  NimbusVersion* = $NimbusMajor & "." & $NimbusMinor & "." & $NimbusPatch
  ## is the version of Nimbus as a string.
