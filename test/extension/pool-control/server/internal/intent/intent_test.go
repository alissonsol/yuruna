// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package intent

import "testing"

// The pool-admin CLIs report failure as JSON on stdout with an empty stderr, so
// the stdout document is the only place the actionable message exists.
func TestCLIErrorFromStdout(t *testing.T) {
	cases := []struct {
		name   string
		stdout string
		want   string
	}{
		{
			name:   "the unconfigured-intent-store message the CLIs actually emit",
			stdout: `{"ok":false,"error":"No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml."}`,
			want:   "No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml.",
		},
		{
			name:   "trailing newline from Console.Out.WriteLine",
			stdout: "{\"ok\":false,\"error\":\"boom\"}\n",
			want:   "boom",
		},
		{
			name:   "a successful document carries no error to surface",
			stdout: `{"ok":true,"pools":[],"testSets":[]}`,
			want:   "",
		},
		{
			name:   "non-JSON output is left to the stderr/process-error fallbacks",
			stdout: "Get-PoolIntent.ps1 : some unstructured text",
			want:   "",
		},
		{name: "empty stdout", stdout: "", want: ""},
		{name: "malformed JSON", stdout: `{"ok":false,`, want: ""},
		{
			name:   "ok absent is treated as failure so the error is still surfaced",
			stdout: `{"error":"partial document"}`,
			want:   "partial document",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := cliErrorFromStdout(tc.stdout); got != tc.want {
				t.Errorf("cliErrorFromStdout() = %q, want %q", got, tc.want)
			}
		})
	}
}
