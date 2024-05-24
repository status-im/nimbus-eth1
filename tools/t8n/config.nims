# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

if defined(evmc_enabled):
  # evmcLoadVMShowDetail log output will intefere with t8n ouput
  switch("define", "chronicles_enabled=off")
else:
  switch("define", "chronicles_enabled=off")
  # TODO: redirect the logs to a custom stream?
  # They are interfering with t8n_test
  #switch("define", "chronicles_default_output_device=stderr")
  #switch("define", "chronicles_runtime_filtering=on")
