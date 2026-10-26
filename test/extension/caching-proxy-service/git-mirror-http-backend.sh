#!/bin/sh
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42c90e56-f7a4-4098-a1c3-984bbd1f9554
# The Go CGI role validates the approved path, applies per-command safe.directory,
# and holds a bounded reader lease until its Git process tree has exited.
exec /usr/local/bin/caching-proxy-service --mirror-role=cgi
