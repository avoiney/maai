//! Test root for modules that do not touch C.
//!
//! `zig build test-pure` runs these without linking Wayland, EGL, or fcft, so the
//! parser, grid, and screen suites stay fast enough to run on every save. The
//! phase 2 reflow property tests and the phase 4 URL scanner tests belong here
//! too — they are exactly the kind of logic that wants sub-second feedback.

test {
    _ = @import("term/cell.zig");
    _ = @import("term/grid.zig");
    _ = @import("term/hints.zig");
    _ = @import("term/mouse.zig");
    _ = @import("term/reclaim.zig");
    _ = @import("term/screen.zig");
    _ = @import("term/screen_test.zig");
    _ = @import("term/selection.zig");
    _ = @import("term/theme.zig");
    _ = @import("term/url.zig");
    _ = @import("term/width.zig");
    _ = @import("vt/parser.zig");
}
