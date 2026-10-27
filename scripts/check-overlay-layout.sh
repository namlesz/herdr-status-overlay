#!/bin/sh
# Real AppKit layout regression; no windows displayed, Herdr or SSH.
set -eu
cd "$(dirname "$0")/.."
swift build
bin=$(swift build --show-bin-path)
if [ -f "$bin/OverlayCore.o" ]; then
    set -- "$bin/OverlayCore.o"
else
    set -- "$bin"/OverlayCore.build/*.o
fi
swiftc -I "$bin" -I "$bin/Modules" "$@" Sources/OverlayApp/PanelController.swift \
    scripts/check-overlay-layout.swift -o .build/check-overlay-layout
.build/check-overlay-layout "$bin/HerdrStatusOverlay_OverlayApp.bundle"
