#!/bin/sh
# Version: 2026.11.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 4267fc32-f82c-4dfe-adf4-1f9f58e5c756
#
# Installed as /etc/NetworkManager/dispatcher.d/90-yuruna-netconsole.
# NetworkManager runs it as root with the interface in $1 and the event in $2.
# Only the events that can change this host's address or next hop re-apply the
# netconsole target; yuruna-netconsole.sh leaves a target that still matches
# untouched.

case "${2:-}" in
    up | dhcp4-change)
        exec /usr/local/lib/yuruna/deep-diagnostics/yuruna-netconsole.sh apply
        ;;
esac
exit 0
