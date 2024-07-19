# Nimbus
# Copyright (c) 2020-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

const postStateTracer* =
  """{
  postState: {},

  // lookupAccount injects the specified account into the postState object.
  lookupAccount: function(addr, db){
    var acc = toHex(addr);
    if (this.postState[acc] === undefined) {
      this.postState[acc] = {
        code:    toHex(db.getCode(addr)),
        storage: {}
      };
    }
  },

  // lookupStorage injects the specified storage entry of the given account into
  // the postState object.
  lookupStorage: function(addr, key, db){
    var acc = toHex(addr);
    var idx = toHex(key);
    this.lookupAccount(addr, db);
    if (this.postState[acc].storage[idx] === undefined) {
      // bug in geth js tracer
      // we will use eth_getProof to fill the storage later
      this.postState[acc].storage[idx] = "";
    }
  },

  // result is invoked when all the opcodes have been iterated over and returns
  // the final result of the tracing.
  result: function(ctx, db) {
    this.lookupAccount(ctx.from, db);
    this.lookupAccount(ctx.to, db);

    // Return the assembled allocations (postState)
    return this.postState;
  },

  // step is invoked for every opcode that the VM executes.
  step: function(log, db) {
    // Add the current account if we just started tracing
    if (this.postState === null){
      this.postState = {};
      // Balance will potentially be wrong here, since this will include the value
      // sent along with the message. We fix that in 'result()'.
      this.lookupAccount(log.contract.getAddress(), db);
    }
    // Whenever new state is accessed, add it to the postState
    switch (log.op.toString()) {
      case "EXTCODECOPY": case "EXTCODESIZE": case "BALANCE":
        this.lookupAccount(toAddress(log.stack.peek(0).toString(16)), db);
        break;
      case "CREATE":
        var from = log.contract.getAddress();
        this.lookupAccount(toContract(from, db.getNonce(from)), db);
        break;
      case "CALL": case "CALLCODE": case "DELEGATECALL": case "STATICCALL":
        this.lookupAccount(toAddress(log.stack.peek(1).toString(16)), db);
        break;
      case 'SSTORE':case 'SLOAD':
        this.lookupStorage(log.contract.getAddress(), toWord(log.stack.peek(0).toString(16)), db);
        break;
    }
  },

  // fault is invoked when the actual execution of an opcode fails.
  fault: function(log, db) {}
}
"""
