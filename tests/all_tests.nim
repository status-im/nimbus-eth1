# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when false:
  import  ./test_code_stream,
          ./test_gas_meter,
          ./test_memory,
          ./test_stack,
          ./test_opcode,
          ./test_storage_backends

when true:
  import  ./test_vm_json
