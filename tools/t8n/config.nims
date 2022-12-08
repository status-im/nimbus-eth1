if defined(evmc_enabled):
  # evmcLoadVMShowDetail log output will intefere with t8n ouput
  switch("define", "chronicles_enabled=off")
else:
  switch("define", "chronicles_default_output_device=stderr")
  switch("define", "chronicles_runtime_filtering=on")
