// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 429e49af-f3ce-413c-b652-2a9a7d9d47b5

package state

import "testing"

// Windows does not expose the Unix FIFO used to block an audit-log append.
func TestHealthAnswersWhileAWriteIsStuck(t *testing.T) {
	t.Skip("needs a FIFO")
}
