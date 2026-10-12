#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
fn main() {
    if !codex_health_windows::handle_permission_hook() {
        codex_health_windows::run();
    }
}
