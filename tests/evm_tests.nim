# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../test_macro

{. warning[UnusedImport]:off .}

# FIXME-howDoIMakeASubSuite: I have no idea whether creating this
# file is a reasonable thing to do. I just want to gather a bunch
# of EVM tests in one place. And I want to be able to gradually
# add to this test suite. --Adam

cliBuilder:
  import  ./test_op_arith,
          ./test_op_bit,
          ./test_op_env,
          ./test_op_memory,
          ./test_op_misc,
          ./test_op_custom
