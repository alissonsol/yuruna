#!/bin/bash
# Test that localhost HTTP returns status 200.
# Avoids shifted characters (|, :, %, {, }) that are unreliable
# when typed via CGEvent on macOS UTM with Apple Virtualization.
curl -k -sI http://localhost | head -n 1