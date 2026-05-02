// nimbus_verified_proxy
// Copyright (c) 2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

// setup-libs downloads the precompiled libverifproxy for the current
// platform and writes it into the verifproxy package's lib/ directory.
//
// Usage (from a dependent project):
//
//	go tool setup-libs
//
// Usage (during development, via go generate from verifproxy/):
//
//	go generate
package main

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	githubOwner = "status-im"
	githubRepo  = "nimbus-eth1"
	modulePath  = "github.com/status-im/nimbus-eth1/nimbus_verified_proxy/library/bindings/go"
)

func main() {
	destDir, err := resolveLibDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "resolve lib dir:", err)
		os.Exit(1)
	}

	goos := runtime.GOOS
	goarch := runtime.GOARCH
	osName := goos
	if goos == "darwin" {
		osName = "macos"
	}
	ext := "a"
	if goos == "windows" {
		ext = "lib"
	}

	assetPrefix := fmt.Sprintf("libverifproxy-%s-%s-", osName, goarch)
	downloadURL, err := fetchLatestAssetURL(assetPrefix)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fetch release:", err)
		os.Exit(1)
	}

	fmt.Printf("Downloading %s ...\n", downloadURL)
	body, err := downloadArchive(downloadURL)
	if err != nil {
		fmt.Fprintln(os.Stderr, "download:", err)
		os.Exit(1)
	}
	defer body.Close()

	libInTar := fmt.Sprintf("build/libverifproxy/libverifproxy.%s", ext)
	dest := filepath.Join(destDir, fmt.Sprintf("libverifproxy.%s", ext))

	if err := ensureWritable(destDir); err != nil {
		fmt.Fprintln(os.Stderr, "mkdir:", err)
		os.Exit(1)
	}

	if err := extractFromTar(body, libInTar, dest); err != nil {
		fmt.Fprintln(os.Stderr, "extract:", err)
		os.Exit(1)
	}
	fmt.Printf("Wrote %s\n", dest)
}

// resolveLibDir returns the lib/ directory inside the verifproxy package.
// When run via go generate (CWD is verifproxy/), returns ./lib.
// When run via go tool from a dependent project, locates the module in the
// module cache via go list.
func resolveLibDir() (string, error) {
	if _, err := os.Stat("verifproxy.go"); err == nil {
		return "lib", nil
	}

	cmd := exec.Command("go", "list", "-m", "-json", modulePath)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("go list -m -json %s: %w", modulePath, err)
	}
	var info struct {
		Dir string `json:"Dir"`
	}
	if err := json.Unmarshal(out, &info); err != nil {
		return "", fmt.Errorf("parse go list output: %w", err)
	}
	if info.Dir == "" {
		return "", fmt.Errorf("module %s not found in module graph", modulePath)
	}
	return filepath.Join(info.Dir, "verifproxy", "lib"), nil
}

// ensureWritable creates destDir, making the parent writable first if needed
// (module cache directories are typically 0555).
func ensureWritable(destDir string) error {
	err := os.MkdirAll(destDir, 0755)
	if err == nil {
		return nil
	}
	if !os.IsPermission(err) {
		return err
	}
	if chmodErr := os.Chmod(filepath.Dir(destDir), 0755); chmodErr != nil {
		return err
	}
	return os.MkdirAll(destDir, 0755)
}

func downloadArchive(url string) (io.ReadCloser, error) {
	resp, err := http.Get(url) //nolint:noctx
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("unexpected status %s", resp.Status)
	}
	return resp.Body, nil
}

func fetchLatestAssetURL(assetPrefix string) (string, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/releases?per_page=20", githubOwner, githubRepo)
	resp, err := http.Get(url) //nolint:noctx
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var releases []struct {
		TagName    string `json:"tag_name"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name               string `json:"name"`
			BrowserDownloadURL string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&releases); err != nil {
		return "", err
	}
	for _, r := range releases {
		if r.Prerelease || strings.Contains(r.TagName, "nightly") {
			continue
		}
		for _, a := range r.Assets {
			if strings.HasPrefix(a.Name, assetPrefix) && strings.HasSuffix(a.Name, ".tar.gz") {
				return a.BrowserDownloadURL, nil
			}
		}
	}
	return "", fmt.Errorf("no asset with prefix %q found in recent releases", assetPrefix)
}

func extractFromTar(r io.Reader, target, dest string) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		if hdr.Name == target || strings.HasSuffix(hdr.Name, "/"+target) {
			out, err := os.Create(dest)
			if err != nil {
				return err
			}
			defer out.Close()
			_, err = io.Copy(out, tr)
			return err
		}
	}
	return fmt.Errorf("%s not found in archive", target)
}
