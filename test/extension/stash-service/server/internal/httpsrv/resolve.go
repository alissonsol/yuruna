// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Host resolution. A stash's hostId is an opaque UUID; to build the remote-host
// deep-link the UI turns it into a reachable stash-UI base URL by reusing the
// pool-aggregator service's existing hostId->address mapping rather than storing
// addresses in stash metadata.
//
// This is BEST-EFFORT and never a hard dependency: an unset or unreachable
// aggregator, or one that has not discovered the host (its discovery is
// proxy-traffic-driven), yields no URL and the UI shows the hostId alone.
//
// The address comes from the pool's own merge of the host's registration and
// the stash service's live presence announce, so resolution works even while a
// host's status service is down.
package httpsrv

import (
	"context"

	"stash-service/internal/config"
)

// resolveStashBaseURL returns the reachable stash-UI base for hostID, or "" when
// it cannot be resolved. The pool client holds the snapshot cache, so a detail
// view that resolves several hosts makes one aggregator request rather than one
// per host.
func (s *Server) resolveStashBaseURL(ctx context.Context, hostID string) string {
	if hostID == "" {
		return ""
	}
	return s.poolClient.ExtensionTarget(ctx, hostID, config.PresenceArea)
}
