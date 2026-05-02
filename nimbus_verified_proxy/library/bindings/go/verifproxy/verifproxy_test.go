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
	"testing"
	"time"

	"github.com/status-im/nimbus-eth1/nimbus_verified_proxy/library/bindings/go/verifproxy"
	"github.com/stretchr/testify/suite"
)

const callTimeout = 30 * time.Second

const ValidConfigJSON = `{
	"eth2Network": "mainnet",
	"trustedBlockRoot": "0xdee3c1ce328851fe9e557ef84bf2f1ffb291a9aa530eb7509fe7b5d9458ae6f4",
	"backendUrls": "https://eth.blockrazor.xyz",
	"beaconApiUrls": "http://testing.mainnet.beacon-api.nimbus.team",
	"logLevel": "DEBUG",
	"logStdout": "Auto"
}`

type VerifProxyTestSuite struct {
	suite.Suite
	ctx *verifproxy.Context

	testBlockHash string
	testTxHash    string
	testFilterId  string
}

func (s *VerifProxyTestSuite) SetupSuite() {
	ctx, err := verifproxy.Start(ValidConfigJSON, nil, nil)
	s.Require().NoError(err, "Failed to start proxy")
	s.Require().NotNil(ctx)
	s.ctx = ctx
}

func (s *VerifProxyTestSuite) TearDownSuite() {
	if s.ctx != nil {
		s.ctx.Stop()
	}
}

func TestVerifProxyAPI(t *testing.T) {
	suite.Run(t, new(VerifProxyTestSuite))
}

func (s *VerifProxyTestSuite) call(method string, params ...interface{}) (string, error) {
	p, err := json.Marshal(params)
	if err != nil {
		return "", fmt.Errorf("marshal params: %w", err)
	}
	return s.ctx.CallRpc(method, string(p), callTimeout)
}

// Basic Chain Data

func (s *VerifProxyTestSuite) TestBlockNumber() {
	result, err := s.call("eth_blockNumber")
	s.Assert().NoError(err)
	s.T().Logf("Block number: %s", result)
	s.Assert().NotEmpty(result)
}

func (s *VerifProxyTestSuite) TestBlobBaseFee() {
	result, err := s.call("eth_blobBaseFee")
	s.Assert().NoError(err)
	s.T().Logf("Blob base fee: %s", result)
	s.Assert().NotEmpty(result)
}

func (s *VerifProxyTestSuite) TestGasPrice() {
	result, err := s.call("eth_gasPrice")
	s.Assert().NoError(err)
	s.T().Logf("Gas price: %s", result)
	s.Assert().NotEmpty(result)
}

func (s *VerifProxyTestSuite) TestMaxPriorityFeePerGas() {
	result, err := s.call("eth_maxPriorityFeePerGas")
	s.Assert().NoError(err)
	s.T().Logf("Max priority fee per gas: %s", result)
	s.Assert().NotEmpty(result)
}

// Account & Storage Access

func (s *VerifProxyTestSuite) TestGetBalance() {
	result, err := s.call("eth_getBalance",
		"0x0000000000000000000000000000000000000000",
		"latest",
	)
	s.Assert().NoError(err)
	s.T().Logf("Balance: %s", result)
}

func (s *VerifProxyTestSuite) TestGetStorageAt() {
	result, err := s.call("eth_getStorageAt",
		"0xdac17f958d2ee523a2206206994597c13d831ec7",
		"0x0000000000000000000000000000000000000000000000000000000000000000",
		"latest",
	)
	s.Assert().NoError(err)
	s.T().Logf("Storage: %s", result)
}

func (s *VerifProxyTestSuite) TestGetTransactionCount() {
	result, err := s.call("eth_getTransactionCount",
		"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
		"latest",
	)
	s.Assert().NoError(err)
	s.T().Logf("Transaction count: %s", result)
	s.Assert().NotEmpty(result)
}

func (s *VerifProxyTestSuite) TestGetCode() {
	result, err := s.call("eth_getCode",
		"0xdac17f958d2ee523a2206206994597c13d831ec7",
		"latest",
	)
	s.Assert().NoError(err)
	s.T().Logf("Code length: %d bytes", len(result))
	s.Assert().NotEmpty(result)
	s.Assert().Greater(len(result), 2, "code should have content beyond 0x prefix")
}

// Block & Uncle Queries

func (s *VerifProxyTestSuite) TestGetBlockByNumber() {
	result, err := s.call("eth_getBlockByNumber", "latest", false)
	s.Assert().NoError(err)
	var block map[string]interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &block))
	if hash, ok := block["hash"].(string); ok {
		s.testBlockHash = hash
	}
	s.T().Logf("Block hash: %s", s.testBlockHash)
}

func (s *VerifProxyTestSuite) TestGetBlockByHash() {
	if s.testBlockHash == "" {
		result, err := s.call("eth_getBlockByNumber", "latest", false)
		s.Require().NoError(err)
		var block map[string]interface{}
		s.Require().NoError(json.Unmarshal([]byte(result), &block))
		s.testBlockHash = block["hash"].(string)
	}
	result, err := s.call("eth_getBlockByHash", s.testBlockHash, false)
	s.Assert().NoError(err)
	var block map[string]interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &block))
	s.Assert().Equal(s.testBlockHash, block["hash"].(string))
}

func (s *VerifProxyTestSuite) TestGetUncleCountByBlockNumber() {
	result, err := s.call("eth_getUncleCountByBlockNumber", "latest")
	s.Assert().NoError(err)
	s.T().Logf("Uncle count by number: %s", result)
	s.Assert().NotEmpty(result)
}

func (s *VerifProxyTestSuite) TestGetUncleCountByBlockHash() {
	if s.testBlockHash == "" {
		s.T().Skip("no block hash available")
	}
	result, err := s.call("eth_getUncleCountByBlockHash", s.testBlockHash)
	s.Assert().NoError(err)
	s.T().Logf("Uncle count by hash: %s", result)
	s.Assert().NotEmpty(result)
}

func (s *VerifProxyTestSuite) TestGetBlockTransactionCountByNumber() {
	result, err := s.call("eth_getBlockTransactionCountByNumber", "latest")
	s.Assert().NoError(err)
	s.T().Logf("Block tx count by number: %s", result)
	s.Assert().NotEmpty(result)
}

func (s *VerifProxyTestSuite) TestGetBlockTransactionCountByHash() {
	if s.testBlockHash == "" {
		s.T().Skip("no block hash available")
	}
	result, err := s.call("eth_getBlockTransactionCountByHash", s.testBlockHash)
	s.Assert().NoError(err)
	s.T().Logf("Block tx count by hash: %s", result)
	s.Assert().NotEmpty(result)
}

// Transaction Queries

func (s *VerifProxyTestSuite) TestGetTransactionByBlockNumberAndIndex() {
	result, err := s.call("eth_getTransactionByBlockNumberAndIndex", "latest", "0x0")
	s.Assert().NoError(err)
	var tx map[string]interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &tx))
	if hash, ok := tx["hash"].(string); ok {
		s.testTxHash = hash
		s.T().Logf("Transaction hash: %s", s.testTxHash)
	}
}

func (s *VerifProxyTestSuite) TestGetTransactionByBlockHashAndIndex() {
	if s.testBlockHash == "" {
		s.T().Skip("no block hash available")
	}
	result, err := s.call("eth_getTransactionByBlockHashAndIndex", s.testBlockHash, "0x0")
	s.Assert().NoError(err)
	var tx map[string]interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &tx))
	s.T().Logf("Parsed transaction JSON")
}

func (s *VerifProxyTestSuite) TestGetTransactionByHash() {
	if s.testTxHash == "" {
		s.T().Skip("no transaction hash available")
	}
	result, err := s.call("eth_getTransactionByHash", s.testTxHash)
	s.Assert().NoError(err)
	var tx map[string]interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &tx))
	s.Assert().Equal(s.testTxHash, tx["hash"].(string))
}

func (s *VerifProxyTestSuite) TestGetTransactionReceipt() {
	if s.testTxHash == "" {
		s.T().Skip("no transaction hash available")
	}
	result, err := s.call("eth_getTransactionReceipt", s.testTxHash)
	s.Assert().NoError(err)
	var receipt map[string]interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &receipt))
	s.Assert().Equal(s.testTxHash, receipt["transactionHash"].(string))
}

// Call / Gas / Access Lists

func (s *VerifProxyTestSuite) TestCall() {
	s.T().Skip("requires a valid call payload")
}

func (s *VerifProxyTestSuite) TestCreateAccessList() {
	txArgs := map[string]string{
		"to":   "0xdac17f958d2ee523a2206206994597c13d831ec7",
		"data": "0x70a08231000000000000000000000000d8da6bf26964af9d7eed9e03e53415d37aa96045",
	}
	result, err := s.call("eth_createAccessList", txArgs, "latest")
	s.Assert().NoError(err)
	var accessList map[string]interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &accessList))
	s.T().Logf("Access list parsed")
}

func (s *VerifProxyTestSuite) TestEstimateGas() {
	txArgs := map[string]string{
		"from":  "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
		"to":    "0x0000000000000000000000000000000000000000",
		"value": "0x1",
	}
	result, err := s.call("eth_estimateGas", txArgs, "latest")
	s.Assert().NoError(err)
	s.T().Logf("Estimated gas: %s", result)
	s.Assert().NotEmpty(result)
}

// Logs & Filters

func (s *VerifProxyTestSuite) TestGetLogs() {
	filterOptions := map[string]string{
		"fromBlock": "latest",
		"toBlock":   "latest",
	}
	result, err := s.call("eth_getLogs", filterOptions)
	s.Assert().NoError(err)
	s.T().Logf("Logs: %s", result)
}

func (s *VerifProxyTestSuite) TestNewFilter() {
	filterOptions := map[string]string{
		"fromBlock": "latest",
		"toBlock":   "latest",
	}
	result, err := s.call("eth_newFilter", filterOptions)
	s.Assert().NoError(err)
	s.testFilterId = result
	s.T().Logf("Filter ID: %s", s.testFilterId)
	s.Assert().NotEmpty(s.testFilterId)
}

func (s *VerifProxyTestSuite) TestGetFilterLogs() {
	if s.testFilterId == "" {
		s.T().Skip("no filter ID available")
	}
	result, err := s.call("eth_getFilterLogs", s.testFilterId)
	s.Assert().NoError(err)
	var logs []interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &logs))
	s.T().Logf("Got %d logs", len(logs))
}

func (s *VerifProxyTestSuite) TestGetFilterChanges() {
	if s.testFilterId == "" {
		s.T().Skip("no filter ID available")
	}
	result, err := s.call("eth_getFilterChanges", s.testFilterId)
	s.Assert().NoError(err)
	var changes []interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &changes))
	s.T().Logf("Got %d changes", len(changes))
}

func (s *VerifProxyTestSuite) TestUninstallFilter() {
	if s.testFilterId == "" {
		s.T().Skip("no filter ID available")
	}
	result, err := s.call("eth_uninstallFilter", s.testFilterId)
	s.Assert().NoError(err)
	s.T().Logf("Uninstall filter result: %s", result)
}

// Receipt Queries

func (s *VerifProxyTestSuite) TestGetBlockReceipts() {
	result, err := s.call("eth_getBlockReceipts", "latest")
	s.Assert().NoError(err)
	var receipts []interface{}
	s.Assert().NoError(json.Unmarshal([]byte(result), &receipts))
	s.T().Logf("Got %d receipts", len(receipts))
}
