#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../../../vendor/nim-unittest2/unittest2,
  ../utils,
  ../mpt_nibbles


suite "Nibbles":


  test "Nibbles64":
    var nibs: Nibbles64
    nibs.bytes = hexToBytesArray[32]("0123456789abcdeffedcba9876543210ffeeddccbbaa99887766554433221100")
    check: $nibs == "0123456789abcdeffedcba9876543210ffeeddccbbaa99887766554433221100"

    check: nibs[0] == 0x0
    check: nibs[1] == 0x1
    check: nibs[20] == 0xb
    check: nibs[62] == 0x0
    check: nibs[63] == 0x0

    nibs[0] = 0xa
    check: nibs[0] == 0xa
    nibs[1] = 2
    check: nibs[1] == 2
    nibs[63] = 0xf
    check: nibs[63] == 0xf
    check: $nibs == "a223456789abcdeffedcba9876543210ffeeddccbbaa9988776655443322110f"
    
    var path: string
    for n in nibs.enumerate():
      path.add n.bitsToHex
    check: path == $nibs


  test "Nibbles":
    var nibs64: Nibbles64
    nibs64.bytes = hexToBytesArray[32]("0123456789abcdeffedcba9876543210ffeeddccbbaa99887766554433221100")

    # even-length
    var nibs = nibs64.slice(0, 62)
    check: $nibs == "0123456789abcdeffedcba9876543210ffeeddccbbaa998877665544332211"
    check: nibs.len == 62

    check: nibs[0] == 0x0
    check: nibs[1] == 0x1
    check: nibs[20] == 0xb
    check: nibs[60] == 0x1
    check: nibs[61] == 0x1

    nibs[0] = 0xa
    check: nibs[0] == 0xa
    nibs[1] = 2
    check: nibs[1] == 2
    nibs[61] = 0xf
    check: nibs[61] == 0xf
    check: $nibs == "a223456789abcdeffedcba9876543210ffeeddccbbaa99887766554433221f"

    # odd-length
    nibs = nibs64.slice(0, 61)
    check: $nibs == "0123456789abcdeffedcba9876543210ffeeddccbbaa99887766554433221"
    check: nibs.len == 61

    check: nibs[0] == 0x0
    check: nibs[1] == 0x1
    check: nibs[20] == 0xb
    check: nibs[59] == 0x2
    check: nibs[60] == 0x1

    nibs[0] = 0xa
    check: nibs[0] == 0xa
    nibs[1] = 2
    check: nibs[1] == 2
    nibs[60] = 0xf
    check: nibs[60] == 0xf
    check: $nibs == "a223456789abcdeffedcba9876543210ffeeddccbbaa9988776655443322f"

    # slices from Nibbles64
    nibs = nibs64.slice(0, 1)
    check: $nibs == "0"
    check: nibs.len == 1
    nibs = nibs64.slice(0, 2)
    check: $nibs == "01"
    nibs = nibs64.slice(0, 5)
    check: $nibs == "01234"
    nibs = nibs64.slice(0, 6)
    check: $nibs == "012345"
    nibs = nibs64.slice(1, 1)
    check: $nibs == "1"
    nibs = nibs64.slice(1, 2)
    check: $nibs == "12"
    nibs = nibs64.slice(61, 1)
    check: $nibs == "1"
    nibs = nibs64.slice(60, 2)
    check: $nibs == "11"
    nibs = nibs64.slice(59, 3)
    check: $nibs == "211"
    nibs = nibs64.slice(58, 4)
    check: $nibs == "2211"
    nibs = nibs64.slice(57, 5)
    check: $nibs == "32211"
    nibs = nibs64.slice(30, 4)
    check: $nibs == "10ff"
    check: nibs.len == 4

    # slices from Nibbles
    nibs = nibs64.slice(0, 62)
    var subnibs = nibs.slice(0, 62)
    check: $subnibs == "0123456789abcdeffedcba9876543210ffeeddccbbaa998877665544332211"
    subnibs = nibs.slice(0, 1)
    check: $subnibs == "0"
    subnibs = nibs.slice(0, 2)
    check: $subnibs == "01"
    subnibs = nibs.slice(0, 5)
    check: $subnibs == "01234"
    subnibs = nibs.slice(61, 1)
    check: $subnibs == "1"
    nibs = nibs64.slice(60, 2)
    check: $nibs == "11"
    nibs = nibs64.slice(59, 3)
    check: $nibs == "211"
    check: nibs[2] == 0x1
    expect RangeDefect:
      discard nibs[3]
    nibs[2] = 0x7
    check: nibs[2] == 0x7
    expect RangeDefect:
      nibs[3] = 0x8

    nibs = nibs64.slice(2, 62)
    expect RangeDefect:
      nibs = nibs64.slice(3, 62)
    nibs = nibs64.slice(61, 1)
    nibs = nibs64.slice(61, 2)
    nibs = nibs64.slice(61, 3)
    expect RangeDefect:
      nibs = nibs64.slice(61, 4)

    nibs = nibs64.slice(0, 62)
    subnibs = nibs.slice(5, 3)
    check: $subnibs == "567"
    nibs = subnibs.slice(2, 1)
    expect RangeDefect:
      nibs = subnibs.slice(3, 1)
    nibs = subnibs.slice(0, 3)
    expect RangeDefect:
      nibs = subnibs.slice(0, 4)
