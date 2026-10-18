// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"mime"
	"strings"
	"testing"
)

func TestDownloadDispositionUnicode(t *testing.T) {
	for _, name := range []string{"report.txt", "café.txt", "cafe\u0301.txt", "資料😀.zip", "مرحبا.txt", "a\"/\\b\r\n\x7f\u202e.txt"} {
		t.Run(name, func(t *testing.T) {
			header := downloadDisposition(name, "abcd", false)
			for _, r := range header {
				if r < 0x20 || r > 0x7e {
					t.Fatalf("non-ASCII/control header: %q", header)
				}
			}
			kind, params, err := mime.ParseMediaType(header)
			if err != nil || kind != "attachment" {
				t.Fatalf("invalid disposition: %q %v", header, err)
			}
			if got, want := params["filename"], sanitizeDownloadName(name, "abcd", false); got != want {
				t.Fatalf("filename* decoded %q, want %q", got, want)
			}
			if !strings.Contains(header, "filename*=UTF-8''") {
				t.Fatal("missing explicit UTF-8 filename")
			}
		})
	}
	if got := downloadDisposition("😀", "abcd", true); !strings.Contains(got, `filename="abcd.zip"`) {
		t.Fatalf("unstable ASCII fallback: %s", got)
	}
	if got := sanitizeDownloadName("\r\n\u202e", "abcd", true); got != "abcd.zip" {
		t.Fatalf("empty fallback = %q", got)
	}
}
