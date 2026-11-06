#!/bin/sh
# macOS may ask for permission to control System Events.
exec /usr/bin/osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode'
