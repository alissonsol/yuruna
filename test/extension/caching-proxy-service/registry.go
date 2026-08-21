// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// RegistryState is what the daemon reports about zot, the OCI mirror that runs
// beside squid.
//
// The three parts come from three different places on purpose, and the split is
// what makes remote mode possible at all: the catalog is zot's own API, the
// canary verdict is already published as Prometheus text on the VM's :80, and
// the prewarm record is a pair of files under the state dir. Only the last one
// needs the box -- so a remote reader loses the prewarm detail and keeps
// everything else, rather than losing the lot.
type RegistryState struct {
	Reachable      bool    `json:"reachable"`
	Repositories   int     `json:"repositories"`
	CanaryOk       bool    `json:"canaryOk"`
	CanaryLatency  float64 `json:"canaryLatencySeconds,omitempty"`
	PrewarmLastRun string  `json:"prewarmLastRun,omitempty"`
	PrewarmHeld    int     `json:"prewarmHeld,omitempty"`
	PrewarmTotal   int     `json:"prewarmTotal,omitempty"`
	Error          string  `json:"error,omitempty"`
}

// zotCatalog is the standard OCI distribution catalog response. Only the names
// are read: the point is "how much is mirrored", not what.
type zotCatalog struct {
	Repositories []string `json:"repositories"`
}

type registryReader struct {
	baseURL   string // zot, e.g. http://127.0.0.1:5000
	metaURL   string // the VM's :80, which serves /zot-meta
	stateRoot string // /var/lib/yuruna, when this daemon can see it
	http      *http.Client
}

func newRegistryReader(baseURL, metaURL, stateRoot string, timeout time.Duration) *registryReader {
	return &registryReader{
		baseURL:   strings.TrimRight(baseURL, "/"),
		metaURL:   strings.TrimRight(metaURL, "/"),
		stateRoot: stateRoot,
		// Same reason as the squid client: an inherited http_proxy would route a
		// read of the mirror through the cache sitting in front of it.
		http: &http.Client{Timeout: timeout, Transport: &http.Transport{Proxy: nil}},
	}
}

func (r *registryReader) state() RegistryState {
	out := RegistryState{}
	if r == nil || r.baseURL == "" {
		out.Error = "no registry URL configured"
		return out
	}
	resp, err := r.http.Get(r.baseURL + "/v2/_catalog")
	if err != nil {
		out.Error = err.Error()
		return out
	}
	defer func() { _, _ = io.Copy(io.Discard, resp.Body); _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		out.Error = "registry catalog: HTTP " + resp.Status
		return out
	}
	var cat zotCatalog
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&cat); err != nil {
		out.Error = "registry catalog is not JSON: " + err.Error()
		return out
	}
	out.Reachable = true
	out.Repositories = len(cat.Repositories)
	r.readCanary(&out)
	r.readPrewarm(&out)
	return out
}

// readCanary takes the verdict from the metadata exporter's Prometheus text
// rather than re-running the probe. The exporter pulls a real manifest every
// ten minutes and is what the dashboard already believes; a second probe from
// here would be a second opinion nobody asked for, and would double the load on
// the one upstream the canary exists to be gentle with.
func (r *registryReader) readCanary(out *RegistryState) {
	if r.metaURL == "" {
		return
	}
	resp, err := r.http.Get(r.metaURL + "/zot-meta")
	if err != nil {
		return
	}
	defer func() { _, _ = io.Copy(io.Discard, resp.Body); _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		name, value, ok := strings.Cut(strings.TrimSpace(line), " ")
		if !ok {
			continue
		}
		switch {
		case name == "yuruna_zot_manifest_ok":
			out.CanaryOk = strings.TrimSpace(value) == "1"
		case strings.HasPrefix(name, "yuruna_zot_manifest_latency_seconds"):
			if f, err := strconv.ParseFloat(strings.TrimSpace(value), 64); err == nil {
				out.CanaryLatency = f
			}
		}
	}
}

// readPrewarm folds in the two files zot-prewarm.sh writes. Both are
// best-effort: a proxy that has never prewarmed is new, not broken, and
// reporting the absence as an error would make every fresh VM look sick. A
// remote reader simply has neither, and says nothing rather than guessing.
func (r *registryReader) readPrewarm(out *RegistryState) {
	if r.stateRoot == "" {
		return
	}
	if meta, err := os.Open(filepath.Join(r.stateRoot, "prewarm-meta.env")); err == nil {
		defer func() { _ = meta.Close() }()
		scanner := bufio.NewScanner(meta)
		for scanner.Scan() {
			key, value, ok := strings.Cut(scanner.Text(), "=")
			if ok && strings.TrimSpace(key) == "YURUNA_PREWARM_LAST_RUN" {
				out.PrewarmLastRun = strings.Trim(strings.TrimSpace(value), `"'`)
			}
		}
	}
	rows, err := os.Open(filepath.Join(r.stateRoot, "prewarm-rows.tsv"))
	if err != nil {
		return
	}
	defer func() { _ = rows.Close() }()
	scanner := bufio.NewScanner(rows)
	for scanner.Scan() {
		// set \t ref \t http_code \t seconds \t state, where state is
		// resident | cold | timeout | failed. The exporter beside this counts
		// resident and cold as held, and so does this: both mean the image is
		// in the mirror, and the difference is only how fast it answered.
		fields := strings.Split(scanner.Text(), "\t")
		if len(fields) < 5 {
			continue
		}
		out.PrewarmTotal++
		if fields[4] == "resident" || fields[4] == "cold" {
			out.PrewarmHeld++
		}
	}
}
