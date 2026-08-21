// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// The two operator switches this daemon owns, and the files that ARE their
// state. Squid has no "get switch" call: presence of the drop-in is the
// setting, which is why reading and writing are both file operations rather
// than a query and a command.
const (
	offlineConfPath    = "/etc/squid/conf.d/yuruna-offline.conf"
	noUpstreamConfPath = "/etc/squid/conf.d/yuruna-no-upstream.conf"

	// The seed installs this; it is what writes noUpstreamConfPath and
	// reloads. Shelling out to it rather than re-implementing the file
	// contents keeps one definition of what "no upstream" means -- the
	// refusal page and the miss_access rule are chosen there.
	noUpstreamHelper = "/usr/local/sbin/yuruna-no-upstream"
)

// SwitchState is what the daemon reports for the two switches. Source names
// how the answer was obtained, because a remote reader infers the setting from
// squid's running config rather than seeing the file, and an operator
// comparing two hosts needs to know which they are looking at.
type SwitchState struct {
	Offline    bool   `json:"offline"`
	NoUpstream bool   `json:"noUpstream"`
	Source     string `json:"source"`
	Detail     string `json:"detail,omitempty"`
}

// readSwitchesLocal answers from the drop-ins themselves. Presence is the
// setting: the seed writes yuruna-offline.conf to turn offline mode on and the
// helper deletes yuruna-no-upstream.conf to turn upstream back on, so a file
// that exists and a file that does not are the whole vocabulary.
func (d *daemon) readSwitchesLocal() SwitchState {
	return SwitchState{
		Offline:    fileExists(d.offlinePath),
		NoUpstream: fileExists(d.noUpstreamPath),
		Source:     "conf.d",
	}
}

// readSwitchesRemote infers both from squid's RUNNING configuration, which is
// the only view a daemon off the box has. It is a weaker answer on purpose and
// says so: the running config reflects the last reconfigure, so a drop-in
// written but not yet applied reads as absent here and as present locally.
func readSwitchesRemote(cfg string) SwitchState {
	state := SwitchState{Source: "mgr:config"}
	for _, line := range strings.Split(cfg, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) == 2 && fields[0] == "offline_mode" && strings.EqualFold(fields[1], "on") {
			state.Offline = true
		}
		// The no-upstream switch is a miss_access deny, not a named directive;
		// the helper writes exactly this rule and nothing else in the shipped
		// config denies a miss.
		if len(fields) >= 3 && fields[0] == "miss_access" && fields[1] == "deny" && fields[2] == "all" {
			state.NoUpstream = true
		}
	}
	state.Detail = "inferred from the running configuration; a drop-in written but not yet reconfigured reads as off"
	return state
}

// errRemoteReadOnly is the refusal every mutation returns in remote mode. It is
// a statement about stock squid, not about this daemon: there is no remote
// reconfigure call, so a change made from off the box could be written but
// never applied. Answering honestly beats writing a file nobody will reload.
var errRemoteReadOnly = errors.New("caching-proxy-remote-readonly")

// applyOffline turns offline mode on or off the way the seed does: write (or
// remove) the drop-in, then reconfigure. Squid re-reads conf.d/*.conf on
// reconfigure, so the file IS the change and the reload is what applies it.
func (d *daemon) applyOffline(on bool) error {
	if d.mode != modeLocal {
		return errRemoteReadOnly
	}
	if on {
		body := "" +
			"# Serve only from cache; never contact origin. Miss returns 504. To\n" +
			"# refresh against origin: delete this file and `squid -k reconfigure`\n" +
			"# (or `systemctl reload squid`).\n" +
			"offline_mode on\n"
		if err := writeFileAtomic(d.offlinePath, body); err != nil {
			return err
		}
	} else if err := removeIfPresent(d.offlinePath); err != nil {
		return err
	}
	return d.reconfigure()
}

// applyNoUpstream delegates to the seed's helper rather than writing the
// drop-in here. The helper owns what the switch MEANS -- the miss_access rule
// and the refusal template it points at -- and two writers of one config file
// is how the two drift.
func (d *daemon) applyNoUpstream(on bool) error {
	if d.mode != modeLocal {
		return errRemoteReadOnly
	}
	verb := "off"
	if on {
		verb = "on"
	}
	if _, err := os.Stat(d.noUpstreamHelper); err != nil {
		return fmt.Errorf("the no-upstream helper is not installed at %s: %w", d.noUpstreamHelper, err)
	}
	out, err := d.run(d.noUpstreamHelper, verb)
	if err != nil {
		return fmt.Errorf("%s %s: %w (%s)", d.noUpstreamHelper, verb, err, strings.TrimSpace(out))
	}
	return nil
}

// reconfigure asks the running squid to re-read its configuration. `squid -k
// reconfigure` is what the seed uses and what the operator runs by hand, so a
// change applied by this daemon and one applied over SSH take the same path.
func (d *daemon) reconfigure() error {
	out, err := d.run(d.squidBinary, "-k", "reconfigure")
	if err != nil {
		return fmt.Errorf("squid -k reconfigure: %w (%s)", err, strings.TrimSpace(out))
	}
	return nil
}

// runCommand is the real exec, injected so tests never touch a squid.
func runCommand(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func removeIfPresent(path string) error {
	err := os.Remove(path)
	if err != nil && errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// writeFileAtomic writes through a temp file in the same directory and renames.
// A squid reconfigure racing a half-written drop-in is a parse error that takes
// the proxy down for every guest on the lab, so the file must never be
// observable in a partial state.
func writeFileAtomic(path, body string) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".yuruna-switch-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if _, err := tmp.WriteString(body); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(name, 0o644); err != nil {
		return err
	}
	return os.Rename(name, path)
}
