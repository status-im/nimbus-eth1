# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../test_macro

{. warning[UnusedImport]:off .}

# This file is just meant to gather a bunch of EVM tests in one
# place. I want to be able to gradually add to this test suite.
# --Adam

when not defined(evmc_enabled):
  cliBuilder:
    import  ./test_op_arith,
            ./test_op_bit,
            ./test_op_env,
            ./test_op_memory,
            ./test_op_misc,
            ./test_op_custom,
            ./test_tracer_json
