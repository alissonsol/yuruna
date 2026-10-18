// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

// handoverLedger survives a collector restart and the Loki presence rehydrate.
// Historical streams and archive paths retain their original host IDs.
type handoverLedger struct {
	Version int               `json:"version"`
	Aliases map[string]string `json:"aliases"`
}

var errHandoverPersistence = errors.New("host handover could not be persisted")

func canonicalHostID(aliases map[string]string, id string) string {
	for i := 0; i < len(aliases); i++ {
		next := aliases[id]
		if next == "" {
			break
		}
		id = next
	}
	return id
}

func validateHandovers(aliases map[string]string) error {
	for old, next := range aliases {
		if !validForgetHostID(old) || !validForgetHostID(next) || old != strings.ToLower(old) || next != strings.ToLower(next) || old == next {
			return fmt.Errorf("invalid host handover %q -> %q", old, next)
		}
		seen := map[string]bool{}
		for id := old; aliases[id] != ""; id = aliases[id] {
			if seen[id] {
				return fmt.Errorf("host handover cycle at %q", id)
			}
			seen[id] = true
		}
	}
	return nil
}

func (s *poolState) loadHandovers() error {
	if s.handoverFile == "" {
		return nil
	}
	data, err := os.ReadFile(s.handoverFile)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read host handovers: %w", err)
	}
	var ledger handoverLedger
	if err := json.Unmarshal(data, &ledger); err != nil {
		return fmt.Errorf("decode host handovers: %w", err)
	}
	if ledger.Version != 1 || ledger.Aliases == nil {
		return errors.New("unsupported host handover ledger")
	}
	if err := validateHandovers(ledger.Aliases); err != nil {
		return err
	}
	s.handovers = ledger.Aliases
	return nil
}

// persistHandovers writes a complete replacement on the same filesystem and
// syncs it before acknowledging the handover. Caller holds s.mu.
func (s *poolState) persistHandovers(aliases map[string]string) error {
	if s.handoverFile == "" {
		return errors.New("host handover state file is not configured")
	}
	data, err := json.MarshalIndent(handoverLedger{Version: 1, Aliases: aliases}, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.handoverFile)
	tmp, err := os.CreateTemp(dir, ".handovers-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), s.handoverFile); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	if err := d.Sync(); err != nil && runtime.GOOS != "windows" {
		return err
	}
	return nil
}

func (s *poolState) handoverHost(oldID, newID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if current := s.handovers[oldID]; current != "" {
		if current == newID {
			// A retry after a lost response also repairs a ledger removed while
			// this process stayed up; success still means persisted state.
			if err := s.persistHandovers(s.handovers); err != nil {
				return fmt.Errorf("%w: %v", errHandoverPersistence, err)
			}
			return nil
		}
		return errors.New("old host identity was already handed to another host")
	}
	if s.handovers[newID] != "" {
		return errors.New("the new host identity is already retired")
	}
	old, next := s.hosts[oldID], s.hosts[newID]
	if old == nil || next == nil {
		return errors.New("both host identities must still be known to the aggregator")
	}
	if old.Reachable || !next.Reachable || old.BaseURL == "" || old.BaseURL != next.BaseURL {
		return errors.New("the old identity must be unreachable and the new identity reachable at the same address")
	}
	copyAliases := make(map[string]string, len(s.handovers)+1)
	for k, v := range s.handovers {
		copyAliases[k] = v
	}
	copyAliases[oldID] = newID
	if err := s.persistHandovers(copyAliases); err != nil {
		return fmt.Errorf("%w: %v", errHandoverPersistence, err)
	}
	s.handovers = copyAliases
	delete(s.hosts, oldID)
	delete(s.incident, oldID)
	if oldFailures := s.failWindow[oldID]; len(oldFailures) != 0 {
		s.failWindow[newID] = append(s.failWindow[newID], oldFailures...)
		sort.Slice(s.failWindow[newID], func(i, j int) bool { return s.failWindow[newID][i].t.Before(s.failWindow[newID][j].t) })
	}
	delete(s.failWindow, oldID)
	delete(s.footprint, oldID)
	for k := range s.announce {
		if strings.HasPrefix(k, oldID+"|") {
			delete(s.announce, k)
		}
	}
	for k := range s.extHealth {
		if strings.HasPrefix(k, oldID+"|") {
			delete(s.extHealth, k)
		}
	}
	// Preserve pass/fail and cycle dedup state under the old key. Output paths
	// project them through the alias; removing them would lose live counts.
	s.statsMu.Lock()
	s.statsEpoch++
	clear(s.statsCache)
	s.statsMu.Unlock()
	return nil
}

func (s *poolState) handleHandoverHost(w http.ResponseWriter, r *http.Request) {
	if s.authToken == "" || s.handoverFile == "" {
		http.Error(w, "host handover is not configured", http.StatusServiceUnavailable)
		return
	}
	if !s.requireInternalBearer(w, r) {
		return
	}
	var body struct {
		OldHostID string `json:"oldHostId"`
		NewHostID string `json:"newHostId"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	if err := decoder.Decode(&body); err != nil || !validForgetHostID(body.OldHostID) || !validForgetHostID(body.NewHostID) || body.OldHostID == body.NewHostID {
		http.Error(w, "oldHostId and newHostId must be distinct 42-prefixed host IDs", http.StatusBadRequest)
		return
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		http.Error(w, "one handover request is required", http.StatusBadRequest)
		return
	}
	body.OldHostID = strings.ToLower(body.OldHostID)
	body.NewHostID = strings.ToLower(body.NewHostID)
	if body.OldHostID == body.NewHostID {
		http.Error(w, "oldHostId and newHostId must be different", http.StatusBadRequest)
		return
	}
	if err := s.handoverHost(body.OldHostID, body.NewHostID); err != nil {
		status := http.StatusConflict
		if errors.Is(err, errHandoverPersistence) {
			status = http.StatusServiceUnavailable
		}
		http.Error(w, err.Error(), status)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = fmt.Fprintf(w, `{"ok":true,"oldHostId":%q,"newHostId":%q}`, body.OldHostID, body.NewHostID)
}

// hostAliasIDs returns the canonical identity and sorted historical IDs.
func (s *poolState) hostAliasIDs(id string) (string, []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	canonical := canonicalHostID(s.handovers, id)
	ids := []string{canonical}
	for old := range s.handovers {
		if canonicalHostID(s.handovers, old) == canonical {
			ids = append(ids, old)
		}
	}
	sort.Strings(ids)
	return canonical, ids
}

// handleHostAliases lets clients query historical IDs belonging to one current
// host so raw Loki records and archive links remain addressable.
func (s *poolState) handleHostAliases(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("hostId")
	if !validForgetHostID(id) {
		http.Error(w, "hostId must be a 42-prefixed host ID", http.StatusBadRequest)
		return
	}
	id = strings.ToLower(id)
	canonical, ids := s.hostAliasIDs(id)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(struct {
		CanonicalHostID string   `json:"canonicalHostId"`
		HostIDs         []string `json:"hostIds"`
	}{canonical, ids})
}

// handleHostHistory projects the original Loki streams into one logical host
// history. The records keep their source hostId for audit and old deep links.
func (s *poolState) handleHostHistory(w http.ResponseWriter, r *http.Request) {
	if s.authToken == "" {
		http.Error(w, "history access is not configured", http.StatusServiceUnavailable)
		return
	}
	if !s.requireInternalBearer(w, r) {
		return
	}
	id, window := r.URL.Query().Get("hostId"), r.URL.Query().Get("range")
	if window == "" {
		window = "30d"
	}
	if !validForgetHostID(id) || !poolStatsRanges[window] {
		http.Error(w, "valid hostId and range (1h, 24h, 7d, 30d) required", http.StatusBadRequest)
		return
	}
	id = strings.ToLower(id)
	if s.lokiURL == "" || s.httpClient == nil {
		http.Error(w, "Loki is unavailable", http.StatusServiceUnavailable)
		return
	}
	canonical, ids := s.hostAliasIDs(id)
	// time.ParseDuration does not recognize days, although 7d and 30d are
	// supported by the pool statistics API and exposed to operators here.
	durations := map[string]time.Duration{
		"1h": time.Hour, "24h": 24 * time.Hour,
		"7d": 7 * 24 * time.Hour, "30d": 30 * 24 * time.Hour,
	}
	duration := durations[window]
	now := time.Now().UTC()
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=~".+",hostId=~%q,src=~"cycle|event|incident"}`, "^("+strings.Join(ids, "|")+")$"))
	params.Set("start", strconv.FormatInt(now.Add(-duration).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(now.UnixNano(), 10))
	params.Set("limit", "1000")
	params.Set("direction", "backward")
	ctx, cancel := context.WithTimeout(r.Context(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryRangeURL(s.lokiURL)+"?"+params.Encode(), nil)
	if err != nil {
		http.Error(w, "history query could not be built", http.StatusInternalServerError)
		return
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		http.Error(w, "history query failed", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		http.Error(w, "history query failed", http.StatusBadGateway)
		return
	}
	var result struct {
		Data struct {
			Result []struct {
				Stream map[string]string `json:"stream"`
				Values [][2]string       `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&result); err != nil {
		http.Error(w, "history response was invalid", http.StatusBadGateway)
		return
	}
	type historyEntry struct {
		Timestamp string `json:"timestampUnixNs"`
		HostID    string `json:"hostId"`
		Source    string `json:"source"`
		Line      string `json:"line"`
	}
	entries := make([]historyEntry, 0)
	for _, stream := range result.Data.Result {
		for _, pair := range stream.Values {
			entries = append(entries, historyEntry{pair[0], stream.Stream["hostId"], stream.Stream["src"], pair[1]})
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Timestamp > entries[j].Timestamp })
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(struct {
		CanonicalHostID string         `json:"canonicalHostId"`
		HostIDs         []string       `json:"hostIds"`
		Range           string         `json:"range"`
		Truncated       bool           `json:"truncated"`
		Entries         []historyEntry `json:"entries"`
	}{canonical, ids, window, len(entries) >= 1000, entries})
}
