// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package intent

import (
	"os"
	"path/filepath"
	"testing"
)

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "pool-control.env")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// The config file is the operator's no-rebuild escape hatch: the intent URL is
// otherwise fixed when cloud-init bakes the seed.
func TestResolveIntentURLPrefersConfigFile(t *testing.T) {
	cfg := writeConfig(t, "POOL_CONTROL_HTTP_ADDR=0.0.0.0:80\nPOOL_CONTROL_INTENT_GIT_URL=/mnt/yuruna-pool/pool-intent.git\n")
	r := &Runner{IntentGitUrl: "/stale/from/launch.git", ConfigPath: cfg}

	if got := r.IntentURL(); got != "/mnt/yuruna-pool/pool-intent.git" {
		t.Errorf("IntentURL() = %q, want the config-file value", got)
	}
}

// Every fallback path must land on the launch value rather than empty: an
// unreadable or incomplete file must not silently disable the intent store.
func TestResolveIntentURLFallsBackToLaunchValue(t *testing.T) {
	const launch = "/launch/pool-intent.git"
	cases := []struct {
		name       string
		configPath string
	}{
		{"no config path configured", ""},
		{"config file does not exist", filepath.Join(t.TempDir(), "absent.env")},
		{"file present but key absent", writeConfig(t, "POOL_CONTROL_HTTP_ADDR=0.0.0.0:80\n")},
		{"key present but empty", writeConfig(t, "POOL_CONTROL_INTENT_GIT_URL=\n")},
		{"key present but only whitespace", writeConfig(t, "POOL_CONTROL_INTENT_GIT_URL=   \n")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := &Runner{IntentGitUrl: launch, ConfigPath: tc.configPath}
			if got := r.IntentURL(); got != launch {
				t.Errorf("IntentURL() = %q, want the launch value %q", got, launch)
			}
		})
	}
}

// An operator hand-editing the file may quote the value the way the surrounding
// shell syntax suggests; the quotes must not become part of the path.
func TestResolveIntentURLStripsQuoting(t *testing.T) {
	for _, body := range []string{
		"POOL_CONTROL_INTENT_GIT_URL=\"/mnt/yuruna-pool/pool-intent.git\"\n",
		"POOL_CONTROL_INTENT_GIT_URL='/mnt/yuruna-pool/pool-intent.git'\n",
		"  POOL_CONTROL_INTENT_GIT_URL=/mnt/yuruna-pool/pool-intent.git  \n",
	} {
		r := &Runner{ConfigPath: writeConfig(t, body)}
		if got := r.IntentURL(); got != "/mnt/yuruna-pool/pool-intent.git" {
			t.Errorf("IntentURL() = %q for body %q", got, body)
		}
	}
}

// Re-reading per call is the whole point: a value edited while the daemon runs
// must take effect without a restart.
func TestResolveIntentURLSeesAnEditWithoutRestart(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pool-control.env")
	if err := os.WriteFile(p, []byte("POOL_CONTROL_INTENT_GIT_URL=/first.git\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &Runner{ConfigPath: p}
	if got := r.IntentURL(); got != "/first.git" {
		t.Fatalf("IntentURL() = %q, want /first.git", got)
	}

	if err := os.WriteFile(p, []byte("POOL_CONTROL_INTENT_GIT_URL=/second.git\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := r.IntentURL(); got != "/second.git" {
		t.Errorf("IntentURL() = %q after edit, want /second.git (value must not be cached)", got)
	}
}

// A key that merely shares the prefix must not be mistaken for the real one.
func TestResolveIntentURLIgnoresPrefixCollision(t *testing.T) {
	r := &Runner{
		IntentGitUrl: "/launch.git",
		ConfigPath:   writeConfig(t, "POOL_CONTROL_INTENT_GIT_URL_BACKUP=/decoy.git\n"),
	}
	if got := r.IntentURL(); got != "/launch.git" {
		t.Errorf("IntentURL() = %q, want the launch value", got)
	}
}
