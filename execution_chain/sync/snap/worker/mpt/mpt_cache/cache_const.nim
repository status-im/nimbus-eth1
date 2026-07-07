# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  ../../../../wire_protocol/snap/snap_types

const
  EmptyProof* = seq[ProofNode].default

  extraTraceMessages* = true
    ## Enable additional logging noise

type
  MptAsmCol* = enum
    cInvalid = 0                                    # not a valid column marker

    gHeaderBal = 10                                 # group, not used as column
    cHeader                                         # header chain by block num
    cBal                                            # block access lists

    gDownloadData = 20                              # group, not used as column
    cStateData                                      # root -> block hash/number
    cAccount                                        # as fetched from network
    cStoSlot                                        # ditto
    cByteCode                                       # ditto

    gPartMptAssembly = 30                           # group, not used as column
    cAccKvt                                         # accounts MPT
    cStoKvt                                         # storage slots MPT
    cCodeKvt                                        # contract codes table

    # These will become obsolete, soon
    cAccDnglKvt                                     # dangling acc nodes links
    cStoDnglKvt                                     # dangling sto nodes links
    cCodeMissKvt                                    # missing contract links

    gFlatTables = 40                                # group, not used as column
    cLeafIntv                                       # missing accounts/slots
    cFlatAcc                                        # flat accounts table
    cFlatSlot                                       # flat storage slots table
    cFlatCode                                       # contract codes table

# End
