// nimbus_verified_proxy
// Copyright (c) 2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

package verifproxy

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const lightClientPath = "/eth/v1/beacon/light_client"

func beaconRequestURL(baseURL string, endpoint string, params string) (string, error) {
	var p struct {
		BlockRoot   string      `json:"block_root"`
		StartPeriod json.Number `json:"start_period"`
		Count       json.Number `json:"count"`
	}
	if params != "" && params != "null" {
		if err := json.Unmarshal([]byte(params), &p); err != nil {
			return "", fmt.Errorf("beacon params for %s: %w", endpoint, err)
		}
	}

	base := strings.TrimRight(baseURL, "/") + lightClientPath
	switch endpoint {
	case "getLightClientBootstrap":
		return base + "/bootstrap/0x" + strings.TrimPrefix(p.BlockRoot, "0x"), nil
	case "getLightClientUpdatesByRange":
		q := url.Values{}
		q.Set("start_period", p.StartPeriod.String())
		q.Set("count", p.Count.String())
		return base + "/updates?" + q.Encode(), nil
	case "getLightClientOptimisticUpdate":
		return base + "/optimistic_update", nil
	case "getLightClientFinalityUpdate":
		return base + "/finality_update", nil
	}
	return "", fmt.Errorf("unknown beacon endpoint: %s", endpoint)
}

func SendBeaconRequest(baseURL string, endpoint string, params string) (json.RawMessage, error) {
	reqURL, err := beaconRequestURL(baseURL, endpoint, params)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequest(http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: 60 * time.Second}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("http error: %s", resp.Status)
	}

	var result json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	return result, nil
}
