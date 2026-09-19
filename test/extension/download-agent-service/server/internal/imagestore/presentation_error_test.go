// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"errors"
	"strings"
	"testing"
)

func TestRecordedRefreshFailureCarriesStablePresentationAndKeepsCompatibilityText(t *testing.T) {
	body := []byte("truncated test-only artifact")
	agent := newTestAgent(t, Options{PoolDir: t.TempDir(), Transport: ubuntuFixture(t, body, false, len(body)+4096)})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	flight, started := agent.startRefresh(id, false)
	if !started {
		t.Fatal("fixture refresh was not started")
	}
	<-flight.Done()
	var presented *presentationError
	if !errors.As(flight.Err(), &presented) || presented.presentation.code != "download.refresh_size_mismatch" {
		t.Fatalf("missing typed failure: %v", flight.Err())
	}
	if !strings.Contains(flight.Err().Error(), "HEAD reported") {
		t.Fatal("compatibility error text changed")
	}
	entry := agent.decorate(Entry{ID: id}, fixedNow)
	if entry.LastError != flight.Err().Error() || entry.LastErrorCode != presented.presentation.code || entry.LastErrorArguments["expected"] != int64(len(body)+4096) || entry.LastErrorArguments["actual"] != int64(len(body)) {
		t.Fatalf("failure metadata lost: %+v", entry)
	}
	entry.LastErrorArguments["actual"] = int64(0)
	if agent.decorate(Entry{ID: id}, fixedNow).LastErrorArguments["actual"] != int64(len(body)) {
		t.Fatal("a returned presentation map mutates retained state")
	}
	if _, ok, _ := agent.store.ReadPointer(id); ok {
		t.Fatal("failed artifact was promoted")
	}
}
