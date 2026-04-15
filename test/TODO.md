# Test Harness: Security and Resilience TODO

Items identified during code review that require non-trivial changes.

## MEDIUM priority

### Improve path traversal check to handle symlinks
**File:** `Start-StatusServer.ps1` (lines 154-155)
The current check uses `GetFullPath()` + `StartsWith()` which does not follow
symlinks. A symlink inside `status/` pointing outside the directory would bypass
the check. Consider using `[System.IO.Path]::GetFullPath()` on the resolved
target, or reject symlinks entirely with a `-not (Get-Item).LinkType` check.

### Race condition in status.json writes
**File:** `modules/Test.Status.psm1` (lines 194-198)
The status file is written via temp-file + `Move-Item`, which is nearly atomic
on most OSes. However, the HTTP server reads the file concurrently. On Windows,
`Move-Item -Force` can briefly leave the target missing. Consider file locking
or a double-buffer approach (write to `status.next.json`, then rename).

### Clear API key from memory after use
**File:** `Invoke-TestRunner.ps1`
The `$Config` hashtable holds the Resend API key for the entire lifetime of the
runner. After sending a notification, zero out the key:
`$Config.secrets.resend.apiKey = $null`. Re-read it from disk only when
needed.

### Harden bash command for macOS server launch
**File:** `Start-StatusServer.ps1` (line 205)
The `$stdErr` path is interpolated into a `bash -c` string. If the path contains
shell metacharacters, they could be interpreted. Use proper shell quoting or pass
arguments via an array rather than string concatenation.
