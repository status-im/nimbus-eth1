# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

const
  eestReleases* = [
    "eest_mainnet",

    # Per mainnet@v21.0.0 release, it already contains
    # glamsterdam latest changes + additional changes not
    # included in glamsterdam-tests@v8.1.4.
    # Disable eest_devnet test until we have new release of
    # next devnet.
    # "eest_devnet",
  ]
