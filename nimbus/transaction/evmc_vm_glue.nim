# Nimbus - Binary compatibility on the VM side of the EVMC API interface
#
# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#{.push raises: [Defect].}

import
  ./host_types, evmc/evmc, stew/ranges/ptr_arith,
  ".."/[vm_types, vm_computation, vm_state_transactions]

proc evmcReleaseResult(result: var evmc_result) {.cdecl.} =
  dealloc(result.output_data)

proc evmcExecute(vm: ptr evmc_vm, hostInterface: ptr evmc_host_interface,
                 hostContext: evmc_host_context, rev: evmc_revision,
                 msg: var evmc_message, code: ptr byte,
                 code_size: csize_t): evmc_result {.cdecl.} =
  # TODO: Obviously we are cheating here at the moment, knowing the caller type.
  # TODO: This lets the host read extra results needed for tests, but it
  # means the Nimbus EVM cannot be used by a non-Nimbus host, yet.
  let host = cast[TransactionHost](hostContext)
  var c = host.computation

  # Allocate `Computation` on demand, and leave it in `host` for that to
  # extract additional results.
  #if c.isNil:
  #  let cMsg = hostToComputationMessage(host.msg)
  #  # TODO: Can we avoid `seq[byte]` so we don't have to copy the code?
  #  let codeSeq = if code_size <= 0: @[]
  #                else: @(makeOpenArray(code, code_size.int))
  #  c = newComputation(host.vmState, cMsg, codeSeq)
  #  c.host.init(cast[ptr nimbus_host_interface](hostInterface), hostContext)
  #  host.computation = c

  c.host.init(cast[ptr nimbus_host_interface](hostInterface), hostContext)
  try:
    execComputation(c)
  except Exception as e:
    c.setError("Caught error " & e.repr, true);

  # When output size is zero, output data pointer may be null.
  var output_data: ptr byte
  var output_size: int
  if c.output.len > 0:
    # TODO: Don't use a copy, share the underlying data and use `GC_ref`.
    # Return a copy, because reference counting is complicated across the
    # shared library boundary.  We could use a refcount but we don't have a
    # `ref seq[byte]` to start with, so need to check `GC_ref` on a non-ref
    # `seq` does what we want first.
    output_size = c.output.len
    # The `alloc` here matches `dealloc` in `evmcReleaseResult`.
    output_data = cast[ptr byte](alloc(output_size))
    copyMem(output_data, c.output[0].addr, output_size)

  return evmc_result(
    # Standard EVMC result, if a bit generic.
    status_code: if c.isSuccess:            EVMC_SUCCESS
                 elif not c.error.burnsGas: EVMC_REVERT
                 else:                      EVMC_FAILURE,
    # Gas left is required to be zero when not `EVMC_SUCCESS` or `EVMC_REVERT`.
    gas_left:    if result.status_code notin {EVMC_SUCCESS, EVMC_REVERT}: 0'i64
                 else: c.gasMeter.gasRemaining.int64,
    output_data: output_data,
    output_size: output_size.csize_t,
    release:     if output_data.isNil: nil
                 else: evmcReleaseResult
    # Nim defaults are fine for `create_address` and `padding`, zero bytes.
  )

when defined(vm2_enabled):
  const evmcName  = "Nimbus EVM (vm2)"
else:
  const evmcName  = "Nimbus EVM (vm1)"

const evmcVersion = "0.0.1"

proc evmcGetCapabilities(vm: ptr evmc_vm): evmc_capabilities {.cdecl.} =
  {EVMC_CAPABILITY_EVM1, EVMC_CAPABILITY_PRECOMPILES}

proc evmcSetOption(vm: ptr evmc_vm, name, value: cstring): evmc_set_option_result {.cdecl.} =
  return EVMC_SET_OPTION_INVALID_NAME

proc evmcDestroy(vm: ptr evmc_vm) {.cdecl.} =
  GC_unref(cast[ref evmc_vm](vm))

proc evmc_create_nimbus_evm(): ptr evmc_vm {.cdecl, exportc.} =
  ## Entry point to the Nimbus EVM, using an EVMC compatible interface.
  ## This is an exported C function.  EVMC specifies the function must
  ## have this name format when exported from a shared library.
  let vm = (ref evmc_vm)(
    abi_version:      EVMC_ABI_VERSION,
    name:             evmcName,
    version:          evmcVersion,
    destroy:          evmcDestroy,
    execute:          evmcExecute,
    get_capabilities: evmcGetCapabilities,
    set_option:       evmcSetOption
  )
  # Keep an extra reference on this, until `evmcDestroy` is called.
  GC_ref(vm)
  return cast[ptr evmc_vm](vm)

# This code assumes fields, methods and types of ABI version 9, and must be
# checked for compatibility if the `import evmc/evmc` major version is updated.
when EVMC_ABI_VERSION != 9:
  {.error: ("This code assumes EVMC_ABI_VERSION 9;" &
            " update the code to use EVMC_ABI_VERSION " & $EVMC_ABI_VERSION).}
