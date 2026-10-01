// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNumericFallback(t *testing.T) {
	for _, number := range []string{strings.Repeat("9", 400) + ".1", "999999999999999999999.1"} {
		s := newStats()
		e, ok := parseLine(strings.Replace(goldenLine, strings.Fields(goldenLine)[0], number, 1), s)
		if !ok || e.TsUnix != 0 || s.fieldErr.Load() != 1 {
			t.Errorf("timestamp: %+v %v", e, s.fieldErr.Load())
		}
		r := &ring{}
		r.push(e)
		w := httptest.NewRecorder()
		handleJSON(r)(w, httptest.NewRequest("GET", "/recent-requests", nil))
		if !json.Valid(w.Body.Bytes()) {
			t.Fatal(w.Body.String())
		}
	}
	s := newStats()
	fields := strings.Fields(goldenLine)
	e, _ := parseLine(strings.Replace(goldenLine, " "+fields[4]+" ", " "+strings.Repeat("9", 40)+" ", 1), s)
	if e.Bytes != 0 || s.fieldErr.Load() != 1 {
		t.Fatalf("bytes: %+v", e)
	}
}
