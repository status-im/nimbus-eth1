// nimbus_verified_proxy
// Copyright (c) 2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

package verifproxy_test

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/status-im/nimbus-eth1/nimbus_verified_proxy/library/bindings/go/verifproxy"
	"github.com/stretchr/testify/require"
)

const testConfig = `{
	"eth2Network":      "mainnet",
	"trustedBlockRoot": "0x9bcb90ec3a294591b77dd2a58e973578715cdc0e6eeeb286bc06dd120057f18b",
	"executionApiUrls": "http://127.0.0.1:19999",
	"beaconApiUrls":    "http://127.0.0.1:19998",
	"logLevel":         "FATAL",
	"logStdout":        "None",
	"syncHeaderStore":  true,
	"freezeAtSlot":     14018020
}`

const (
	dataDir     = "../../../../tests/data"
	callTimeout = 30 * time.Second
)

func readData(name string) (json.RawMessage, error) {
	data, err := os.ReadFile(filepath.Join(dataDir, name))
	if err != nil {
		return nil, err
	}
	return json.RawMessage(data), nil
}

func execTransport(_ string, method, _ string) (json.RawMessage, error) {
	switch method {
	case "eth_getBlockByNumber", "eth_getBlockByHash":
		return readData("block_0x17a2d23.json")
	}
	return nil, fmt.Errorf("exec: no mock for %s", method)
}

func beaconTransport(_ string, endpoint, _ string) (json.RawMessage, error) {
	files := map[string]string{
		"getLightClientBootstrap":        "lc_bootstrap.json",
		"getLightClientUpdatesByRange":   "lc_updates.json",
		"getLightClientOptimisticUpdate": "lc_optimistic.json",
		"getLightClientFinalityUpdate":   "lc_finality.json",
	}
	if f, ok := files[endpoint]; ok {
		return readData(f)
	}
	return nil, fmt.Errorf("beacon: no mock for %s", endpoint)
}

func TestVerifProxy(t *testing.T) {
	ctx, err := verifproxy.Start(testConfig, execTransport, beaconTransport)
	require.NoError(t, err)
	require.NotNil(t, ctx)
	defer ctx.Stop()

	for _, method := range []string{"eth_gasPrice", "eth_maxPriorityFeePerGas"} {
		result, err := ctx.CallRpc(method, "[]", callTimeout)
		require.NoError(t, err, method)
		require.NotEmpty(t, result, method)
	}

	result, err := ctx.CallRpc("eth_getBlockByNumber", `["latest", false]`, callTimeout)
	require.NoError(t, err)
	require.NotEmpty(t, result)
}
