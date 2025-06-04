# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

if not defined(windows):
  # This limits stack usage of each individual function to 1MB - the option is
  # available on some GCC versions but not all - run with `-d:limitStackUsage`
  # and look for .su files in "./build/", "./nimcache/" or $TMPDIR that list the
  # stack size of each function.
  switch("passC", "-fstack-usage -Werror=stack-usage=1048576")
  switch("passL", "-fstack-usage -Werror=stack-usage=1048576")

switch("define", "chronicles_line_numbers")
switch("define", "chronicles_sinks=textlines")
switch("define", "chronicles_disable_thread_id")
switch("define", "chronicles_runtime_filtering=on")
