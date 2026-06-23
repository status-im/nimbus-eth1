// nimbus_verified_proxy
// Copyright (c) 2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/status-im/nimbus-eth1/nimbus_verified_proxy/library/bindings/go/verifproxy"
)

// Selecting an "op-*" network spins up a secondary L2 engine served under the op_ namespace.
// The primary engine then verifies the L1 the rollup settles to (here, mainnet), so eth_*
// targets L1 and op_* targets the OP L2. "opExecutionApiUrls" points at op-geth; the same
// transport callback handles it (just another transport).
const configJSON = `{
  "executionApiUrls": "https://eth.blockrazor.xyz,https://eth.nimbus.xyz",
  "beaconApiUrls": "http://testing.mainnet.beacon-api.nimbus.team,http://www.lightclientdata.org",
  "opExecutionApiUrls": "https://mainnet.optimism.io",
  "eth2Network": "op-mainnet",
  "trustedBlockRoot": "0x1234567890123456789012345678901234567890123456789012345678901234",
  "logLevel": "DEBUG"
}`

func main() {
	ctx, err := verifproxy.Start(configJSON, nil, nil)
	if err != nil {
		log.Fatalf("start: %v", err)
	}
	defer ctx.Stop()

	time.Sleep(2 * time.Second)

	// eth_* targets the L1 engine
	params, _ := json.Marshal([]string{"0xde0B295669a9FD93d5F28D9Ec85E40f4cb697BAe", "latest"})
	result, err := ctx.CallRpc("eth_getBalance", string(params), 30*time.Second)
	if err != nil {
		log.Fatalf("eth_getBalance: %v", err)
	}
	fmt.Printf("eth_getBalance: %s\n", result)

	// op_* targets the L2 (OP Stack) engine — same generic CallRpc, op_ prefix
	opParams, _ := json.Marshal([]string{"0x4200000000000000000000000000000000000016", "safe"})
	opResult, err := ctx.CallRpc("op_getBalance", string(opParams), 30*time.Second)
	if err != nil {
		log.Fatalf("op_getBalance: %v", err)
	}
	fmt.Printf("op_getBalance: %s\n", opResult)
}
