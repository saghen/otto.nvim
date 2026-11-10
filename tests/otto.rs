//! Otto's side, in headless Neovim with a fake agent

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use common::*;

/// Otto's side, in headless Neovim with a fake agent, given blink.lib like `BLINK_LIB=~/code/nvim/blink.lib`
#[test]
fn otto_attributes_changes_to_tool_calls() {
    let Some(blink) = std::env::var_os("BLINK_LIB").map(PathBuf::from).filter(|dir| dir.exists()) else {
        return skip("BLINK_LIB isn't set to blink.lib");
    };
    if skip_unless(&["nvim"]) {
        return;
    }
    let ws = Workspace::new("otto");
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/track.lua");
    let output = Command::new("nvim")
        .args(["--headless", "--clean", "-l"])
        .arg(script)
        .args([Path::new(BIN), &blink, &ws.path()])
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
}
