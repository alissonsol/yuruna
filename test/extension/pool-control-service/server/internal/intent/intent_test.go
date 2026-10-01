// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package intent

import (
	"context"
	"strings"
	"testing"
)

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
			stdout: `{"ok":true,"pools":[],"autoEnrollment":{"enabled":false,"targetPoolId":"","excluded":[]}}`,
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

func TestRemoveHostExclusionArguments(t *testing.T) {
	r := &Runner{Pwsh: "nonexistent-fixture-pwsh", RepoDir: t.TempDir()}
	result := r.RemoveHost(context.Background(), "", "42fixture", true)
	argv := strings.Join(result.Argv, " ")
	if !strings.Contains(argv, "-HostId 42fixture -Exclude") || strings.Contains(argv, "-PoolId") {
		t.Fatalf("exclusion arguments: %v", result.Argv)
	}
	result = r.RemoveHost(context.Background(), "lab", "42fixture")
	argv = strings.Join(result.Argv, " ")
	if !strings.Contains(argv, "-PoolId lab") || strings.Contains(argv, "-Exclude") {
		t.Fatalf("ordinary removal arguments: %v", result.Argv)
	}
}

// Setting and clearing a pool's repositories run one CLI with disjoint flags.
// TestRunnerFlagsMatchScriptParameters proves each flag exists on the script;
// this proves which flags each method sends, so a clear can never carry a URL
// and a set can never be read as a clear.
func TestPoolRepositoriesArguments(t *testing.T) {
	r := &Runner{Pwsh: "nonexistent-fixture-pwsh", RepoDir: t.TempDir()}
	argv := strings.Join(r.SetPoolRepositories(context.Background(), "lab", "https://f", "https://p").Argv, " ")
	if !strings.Contains(argv, "pool/Set-PoolRepository.ps1 -PoolId lab -FrameworkUrl https://f -ProjectUrl https://p") ||
		strings.Contains(argv, "-Clear") || strings.Contains(argv, "-Name") {
		t.Fatalf("set arguments: %s", argv)
	}
	argv = strings.Join(r.ClearPoolRepositories(context.Background(), "lab").Argv, " ")
	if !strings.Contains(argv, "pool/Set-PoolRepository.ps1 -PoolId lab -Clear") ||
		strings.Contains(argv, "-FrameworkUrl") || strings.Contains(argv, "-ProjectUrl") {
		t.Fatalf("clear arguments: %s", argv)
	}
}
