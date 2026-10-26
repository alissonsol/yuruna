// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42b19fe7-5db5-47d1-af6e-2ff18f3ec107

package httpsrv

import "embed"

// webFS holds the static UI assets (pages + JS + CSS), compiled into the
// binary so the daemon is self-contained -- no separate asset deploy. The CSS
// mirrors the status pages' yuruna.common design tokens (light/dark custom
// properties) for visual consistency.
//
//go:embed web
var webFS embed.FS
