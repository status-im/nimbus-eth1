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
	"time"
)

func SendBeaconRequest(baseURL string, endpoint string, params string) (json.RawMessage, error) {
	reqURL, err := url.Parse(baseURL + "/" + endpoint)
	if err != nil {
		return nil, err
	}

	// params is a JSON object — add each key as a query parameter
	if params != "" && params != "null" && params != "{}" {
		var queryParams map[string]string
		if err := json.Unmarshal([]byte(params), &queryParams); err == nil {
			q := reqURL.Query()
			for k, v := range queryParams {
				q.Set(k, v)
			}
			reqURL.RawQuery = q.Encode()
		}
	}

	client := &http.Client{Timeout: 10 * time.Second}

	resp, err := client.Get(reqURL.String())
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
