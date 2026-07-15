# Compact Rounded Menu Panel Design

## Goal

Show the existing menu-panel content in one compact window without vertical scrolling, while preserving every currently displayed value and control. Make the panel genuinely rounded so no rectangular material or background is visible outside its corners.

## Layout

Keep the existing single-column information order:

1. ToolBox header and summary badges
2. CPU and GPU power charts
3. Cable status, when available
4. External display controls, when available
5. Screen wipe and system-awake toggles

Remove the outer vertical `ScrollView`. Reduce visual whitespace rather than removing content: use smaller section insets, tighter inter-section spacing, shorter charts, more compact cable rows, denser display-control rows, and a shorter controls bar. Text and controls remain readable and retain their current labels, status values, cable detail lines, and DDC controls.

The panel remains a stable-width menu-bar surface. Its fixed height will be reduced to match the compact layout. Dynamic cable content keeps the current bounded model; the compact row metrics allow the common active-cable configuration to fit without scrolling.

## Window Shape

The `NSPanel` remains borderless, non-opaque, and clear. The outer glass container becomes the single owner of the rounded silhouette:

- clip all visual-effect, tint, highlight, and hosted-content layers to one continuous rounded boundary;
- keep decorative border paths inside that boundary;
- do not place a rectangular fill behind the rounded container;
- let the `NSPanel` provide the exterior window shadow.

This separates clipping from shadow rendering and prevents a square compositing layer from appearing behind the rounded surface.

## Verification

Add focused tests for the shared panel metrics and rounded-window configuration where the AppKit surface is testable. Run the complete unit test suite and both Debug and Release builds. Launch the built app and visually inspect the menu panel in light and dark appearances, checking that all available sections are visible without scrolling and that all four corners remain transparent outside the rounded silhouette.

