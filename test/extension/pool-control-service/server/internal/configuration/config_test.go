// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package configuration

import (
	"os"
	"path/filepath"
	"testing"
)

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "pool-control-service.env")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// The config file is the operator's no-rebuild escape hatch: the configuration URL is
// otherwise fixed when cloud-init bakes the seed.
func TestResolveConfigurationURLPrefersConfigFile(t *testing.T) {
	cfg := writeConfig(t, "POOL_CONTROL_HTTP_ADDR=0.0.0.0:80\nPOOL_CONTROL_CONFIGURATION_GIT_URL=/mnt/yuruna-pool/pool-configuration.git\n")
	r := &Runner{ConfigurationGitUrl: "/stale/from/launch.git", ConfigPath: cfg}

	if got := r.ConfigurationURL(); got != "/mnt/yuruna-pool/pool-configuration.git" {
		t.Errorf("ConfigurationURL() = %q, want the config-file value", got)
	}
}

// Every fallback path must land on the launch value rather than empty: an
// unreadable or incomplete file must not silently disable the configuration store.
func TestResolveConfigurationURLFallsBackToLaunchValue(t *testing.T) {
	const launch = "/launch/pool-configuration.git"
	cases := []struct {
		name       string
		configPath string
	}{
		{"no config path configured", ""},
		{"config file does not exist", filepath.Join(t.TempDir(), "absent.env")},
		{"file present but key absent", writeConfig(t, "POOL_CONTROL_HTTP_ADDR=0.0.0.0:80\n")},
		{"key present but empty", writeConfig(t, "POOL_CONTROL_CONFIGURATION_GIT_URL=\n")},
		{"key present but only whitespace", writeConfig(t, "POOL_CONTROL_CONFIGURATION_GIT_URL=   \n")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := &Runner{ConfigurationGitUrl: launch, ConfigPath: tc.configPath}
			if got := r.ConfigurationURL(); got != launch {
				t.Errorf("ConfigurationURL() = %q, want the launch value %q", got, launch)
			}
		})
	}
}

// An operator hand-editing the file may quote the value the way the surrounding
// shell syntax suggests; the quotes must not become part of the path.
func TestResolveConfigurationURLStripsQuoting(t *testing.T) {
	for _, body := range []string{
		"POOL_CONTROL_CONFIGURATION_GIT_URL=\"/mnt/yuruna-pool/pool-configuration.git\"\n",
		"POOL_CONTROL_CONFIGURATION_GIT_URL='/mnt/yuruna-pool/pool-configuration.git'\n",
		"  POOL_CONTROL_CONFIGURATION_GIT_URL=/mnt/yuruna-pool/pool-configuration.git  \n",
	} {
		r := &Runner{ConfigPath: writeConfig(t, body)}
		if got := r.ConfigurationURL(); got != "/mnt/yuruna-pool/pool-configuration.git" {
			t.Errorf("ConfigurationURL() = %q for body %q", got, body)
		}
	}
}

// Re-reading per call is the whole point: a value edited while the daemon runs
// must take effect without a restart.
func TestResolveConfigurationURLSeesAnEditWithoutRestart(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pool-control-service.env")
	if err := os.WriteFile(p, []byte("POOL_CONTROL_CONFIGURATION_GIT_URL=/first.git\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &Runner{ConfigPath: p}
	if got := r.ConfigurationURL(); got != "/first.git" {
		t.Fatalf("ConfigurationURL() = %q, want /first.git", got)
	}

	if err := os.WriteFile(p, []byte("POOL_CONTROL_CONFIGURATION_GIT_URL=/second.git\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := r.ConfigurationURL(); got != "/second.git" {
		t.Errorf("ConfigurationURL() = %q after edit, want /second.git (value must not be cached)", got)
	}
}

// A key that merely shares the prefix must not be mistaken for the real one.
func TestResolveConfigurationURLIgnoresPrefixCollision(t *testing.T) {
	r := &Runner{
		ConfigurationGitUrl: "/launch.git",
		ConfigPath:          writeConfig(t, "POOL_CONTROL_CONFIGURATION_GIT_URL_BACKUP=/decoy.git\n"),
	}
	if got := r.ConfigurationURL(); got != "/launch.git" {
		t.Errorf("ConfigurationURL() = %q, want the launch value", got)
	}
}

func TestResolveConfigurationURLMigratesLegacyEnvironment(t *testing.T) {
	cases := []struct {
		name, body, want string
	}{
		{"legacy only", "POOL_CONTROL_INTENT_GIT_URL='/existing/store.git'\n", "/existing/store.git"},
		{"canonical last", "POOL_CONTROL_INTENT_GIT_URL=/legacy.git\nPOOL_CONTROL_CONFIGURATION_GIT_URL=/canonical.git\n", "/canonical.git"},
		{"canonical first", "POOL_CONTROL_CONFIGURATION_GIT_URL=/canonical.git\nPOOL_CONTROL_INTENT_GIT_URL=/legacy.git\n", "/canonical.git"},
		{"canonical empty", "POOL_CONTROL_INTENT_GIT_URL=/legacy.git\nPOOL_CONTROL_CONFIGURATION_GIT_URL=\n", "/launch.git"},
		{"legacy prefix collision", "POOL_CONTROL_INTENT_GIT_URL_BACKUP=/decoy.git\n", "/launch.git"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := &Runner{ConfigurationGitUrl: "/launch.git", ConfigPath: writeConfig(t, tc.body)}
			if got := r.ConfigurationURL(); got != tc.want {
				t.Errorf("ConfigurationURL() = %q, want %q", got, tc.want)
			}
		})
	}
}
