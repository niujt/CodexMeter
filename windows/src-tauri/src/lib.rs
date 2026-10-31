mod permissions;
mod state;
mod updates;
mod api;
mod api_credentials;
use chrono::{DateTime, Utc};
use codex_health_usage::{context, Snapshot};
use serde::{Deserialize, Serialize};
use state::{AppState, Bootstrap, Preferences};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager, State,
};

pub fn handle_permission_hook() -> bool {
    let args: Vec<_> = std::env::args_os().collect();
    if args.get(1).is_some_and(|a| a == permissions::HOOK_MARKER) {
        if let Some(queue) = args.get(2) {
            permissions::handle_hook(&PathBuf::from(queue));
        }
        return true;
    }
    false
}
#[tauri::command]
async fn get_app_state(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<Bootstrap, String> {
    Ok(state.bootstrap(&app))
}
#[tauri::command]
async fn read_usage(app: tauri::AppHandle, force: Option<bool>) -> Result<Snapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        app.state::<AppState>().load(&app, force.unwrap_or(false))
    })
    .await
    .map_err(|_| "读取任务无法完成".to_string())?
}
#[tauri::command]
async fn select_directory(app: tauri::AppHandle, path: String) -> Result<Snapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        app.state::<AppState>().select(&app, path)?;
        app.state::<AppState>().load(&app, false)
    })
    .await
    .map_err(|_| "目录选择任务无法完成".to_string())?
}
#[tauri::command]
async fn save_preferences(
    app: tauri::AppHandle,
    preferences: Preferences,
) -> Result<Preferences, String> {
    app.state::<AppState>()
        .update_preferences(&app, preferences)
}
#[tauri::command]
async fn show_dashboard(app: tauri::AppHandle) -> Result<(), String> {
    let w = app.get_webview_window("main").ok_or("主窗口不可用")?;
    w.unminimize().map_err(|_| "无法恢复窗口")?;
    w.show().map_err(|_| "无法显示窗口")?;
    w.set_focus().map_err(|_| "无法激活窗口")?;
    {
        let state = app.state::<AppState>();
        let mut data = state.data.lock().unwrap();
        data.main_visible = true;
        data.focused = true;
        drop(data);
        state.signal(false, false);
    }
    let _ = app.emit_to("main", "visibility-changed", true);
    Ok(())
}
#[tauri::command]
async fn toggle_floating(app: tauri::AppHandle, visible: bool) -> Result<(), String> {
    let mut prefs = app.state::<AppState>().preferences();
    prefs.floating_enabled = visible;
    app.state::<AppState>().update_preferences(&app, prefs)?;
    Ok(())
}
#[tauri::command]
async fn save_floating_position(app: tauri::AppHandle) -> Result<(), String> {
    let w = app.get_webview_window("floating").ok_or("悬浮窗口不可用")?;
    let p = w.outer_position().map_err(|_| "无法读取位置")?;
    let dir = app.path().app_config_dir().map_err(|_| "无法保存位置")?;
    context::write_json(&dir.join("floating-position.json"), &[p.x, p.y])
        .map_err(|_| "无法保存位置".into())
}
#[tauri::command]
async fn install_permission_hook(app: tauri::AppHandle) -> Result<String, String> {
    let state = app.state::<AppState>();
    let prefs = state.preferences();
    let root = prefs
        .directory
        .map(PathBuf::from)
        .ok_or("请先选择 Codex 主目录")?;
    if !root.join("sessions").is_dir() && !root.join("archived_sessions").is_dir() {
        return Err("权限 Hook 需要选择 Codex 主目录".into());
    }
    permissions::install(&root, &state.config)?;
    state.configure_watcher(&app);
    Ok("Hook 已安装，请在 Codex 中使用 /hooks 检查并信任；不会自动允许或拒绝请求。".into())
}
#[tauri::command]
async fn uninstall_permission_hook(app: tauri::AppHandle) -> Result<(), String> {
    let prefs = app.state::<AppState>().preferences();
    permissions::uninstall(
        &prefs
            .directory
            .map(PathBuf::from)
            .ok_or("请先选择数据目录")?,
    )
}
#[tauri::command]
async fn mark_permissions(
    app: tauri::AppHandle,
    id: Option<String>,
    status: String,
) -> Result<(), String> {
    if !["seen", "dismissed", "clear"].contains(&status.as_str()) {
        return Err("无效状态".into());
    }
    app.state::<AppState>().mark_permissions(&app, id, &status)
}
#[tauri::command]
async fn test_permission_notification(app: tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let prefs = state.preferences();
    let root = prefs
        .directory
        .map(PathBuf::from)
        .ok_or("请先选择数据目录")?;
    let event = permissions::sanitize(
        &serde_json::json!({"event_id":format!("test-{}",Utc::now()),"cwd":"测试项目","tool_name":"Bash","requires_user_input":true}),
        Utc::now(),
    );
    let queue = permissions::spool(&state.config, &root);
    context::write_json(
        &queue.join(format!(
            "{}.json",
            context::digest(event.event_id.as_bytes())
        )),
        &event,
    )
    .map_err(|_| "无法创建测试提醒")?;
    state.signal(false, true);
    Ok(())
}
#[tauri::command]
async fn open_codex() -> Result<(), String> {
    #[cfg(windows)]
    {
        std::process::Command::new("explorer.exe")
            .arg("codex://")
            .spawn()
            .map_err(|_| "无法打开 Codex，请确认已安装")?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg("codex://")
            .spawn()
            .map_err(|_| "无法打开 Codex")?;
    }
    Ok(())
}
#[tauri::command]
async fn open_project(app: tauri::AppHandle, path: String) -> Result<(), String> {
    let prefs = app.state::<AppState>().preferences();
    let permitted = prefs.followed_paths.contains(&path)
        || app
            .state::<AppState>()
            .data
            .lock()
            .unwrap()
            .snapshot
            .as_ref()
            .is_some_and(|s| {
                s.projects
                    .iter()
                    .chain(s.today_projects.iter())
                    .chain(s.month_projects.iter())
                    .any(|p| p.name == path)
            });
    if !permitted || !PathBuf::from(&path).is_dir() {
        return Err("项目目录不可访问".into());
    }
    #[cfg(windows)]
    {
        std::process::Command::new("explorer.exe")
            .arg(&path)
            .spawn()
            .map_err(|_| "无法打开项目目录")?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&path)
            .spawn()
            .map_err(|_| "无法打开项目目录")?;
    }
    Ok(())
}
#[derive(Clone, Serialize, Deserialize)]
struct ResetEvent {
    id: String,
    kind: String,
    occurred_at: DateTime<Utc>,
}
#[derive(Deserialize)]
struct ResetPage {
    events: Vec<ResetEvent>,
    next_cursor: Option<String>,
}
#[tauri::command]
async fn get_reset_history(app: tauri::AppHandle) -> Result<Vec<ResetEvent>, String> {
    let root = app
        .state::<AppState>()
        .preferences()
        .directory
        .map(PathBuf::from)
        .ok_or("请先选择 Codex 主目录")?;
    let auth = context::credentials(&root).ok_or("未找到可用的 ChatGPT 登录凭据")?;
    let identity = auth.identity.clone();
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|_| "无法建立重置历史查询")?;
    let mut cursor: Option<String> = None;
    let mut cursors = BTreeSet::new();
    let mut events = BTreeMap::new();
    for _ in 0..100 {
        let current = context::credentials(&root)
            .filter(|a| a.identity == identity)
            .ok_or("账户已变化，请重新查询")?;
        if app
            .state::<AppState>()
            .preferences()
            .directory
            .as_ref()
            .is_none_or(|p| PathBuf::from(p) != root)
        {
            return Err("目录已变化，请重新查询".into());
        }
        let mut request = client
            .get("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/history")
            .bearer_auth(current.token)
            .header("ChatGPT-Account-Id", current.account_id)
            .header("Accept", "application/json");
        if let Some(cursor) = &cursor {
            request = request.query(&[("cursor", cursor)]);
        }
        let response = request
            .send()
            .await
            .map_err(|_| "重置历史查询失败，请检查网络和登录状态")?;
        if response.status() != reqwest::StatusCode::OK {
            return Err(format!(
                "重置历史读取失败（HTTP {}），此接口可能不接受当前登录凭据。",
                response.status().as_u16()
            ));
        }
        if response
            .content_length()
            .is_some_and(|n| n > 2 * 1024 * 1024)
        {
            return Err("重置历史响应过大".into());
        }
        let bytes = response.bytes().await.map_err(|_| "无法读取重置历史")?;
        if bytes.len() > 2 * 1024 * 1024 {
            return Err("重置历史响应过大".into());
        }
        let page: ResetPage = serde_json::from_slice(&bytes).map_err(|_| "重置历史响应无法识别")?;
        if context::credentials(&root).is_none_or(|a| a.identity != identity)
            || app
                .state::<AppState>()
                .preferences()
                .directory
                .as_ref()
                .is_none_or(|p| PathBuf::from(p) != root)
        {
            return Err("读取期间账户或目录已变化，请重新查询".into());
        }
        for event in page.events {
            events.insert(event.id.clone(), event);
        }
        if let Some(next) = page.next_cursor.filter(|s| !s.is_empty()) {
            if !cursors.insert(next.clone()) {
                return Err("重置历史分页未完成，请重试".into());
            }
            cursor = Some(next);
        } else {
            let mut rows: Vec<_> = events
                .into_values()
                .filter(|e| e.occurred_at >= Utc::now() - chrono::Duration::days(30))
                .collect();
            rows.sort_by(|a, b| b.occurred_at.cmp(&a.occurred_at).then(a.id.cmp(&b.id)));
            return Ok(rows);
        }
    }
    Err("重置历史分页未完成，请重试".into())
}
fn restore_floating(app: &tauri::AppHandle) {
    let Some(w) = app.get_webview_window("floating") else {
        return;
    };
    let Ok(dir) = app.path().app_config_dir() else {
        return;
    };
    let position = std::fs::read(dir.join("floating-position.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<[i32; 2]>(&b).ok())
        .or_else(|| {
            std::fs::read_to_string(dir.join("floating-position.txt"))
                .ok()
                .and_then(|s| {
                    let (x, y) = s.trim().split_once(',')?;
                    Some([x.parse().ok()?, y.parse().ok()?])
                })
        });
    let Some([x, y]) = position else { return };
    let Ok(monitors) = w.available_monitors() else {
        return;
    };
    let Ok(size) = w.outer_size() else { return };
    if monitors.iter().any(|m| {
        let p = m.position();
        let s = m.size();
        i64::from(x) >= i64::from(p.x)
            && i64::from(y) >= i64::from(p.y)
            && i64::from(x) + i64::from(size.width) <= i64::from(p.x) + i64::from(s.width)
            && i64::from(y) + i64::from(size.height) <= i64::from(p.y) + i64::from(s.height)
    }) {
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
    }
}
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            get_app_state,
            read_usage,
            select_directory,
            save_preferences,
            show_dashboard,
            toggle_floating,
            save_floating_position,
            install_permission_hook,
            uninstall_permission_hook,
            mark_permissions,
            test_permission_notification,
            open_codex,
            open_project,
            get_reset_history,
            updates::app_version,
            updates::check_app_update,
            updates::install_app_update,
            api::api_status,
            api::api_save_key,
            api::api_load,
            api::api_open_console
        ])
        .setup(|app| {
            let config = app.path().app_config_dir()?;
            let cache = app.path().app_cache_dir()?;
            app.manage(AppState::new(config, cache));
            app.manage(api::ApiState::default());
            if let Some(main) = app.get_webview_window("main") {
                let state = app.state::<AppState>();
                let mut data = state.data.lock().unwrap();
                data.focused = main.is_focused().unwrap_or(false);
                data.main_visible = main.is_visible().unwrap_or(true);
            }
            let show = MenuItem::with_id(app, "show", "打开健康报告", true, None::<&str>)?;
            let floating =
                MenuItem::with_id(app, "floating", "显示 / 隐藏悬浮窗口", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &floating, &quit])?;
            TrayIconBuilder::with_id("health")
                .icon(app.default_window_icon().cloned().ok_or("缺少应用图标")?)
                .tooltip("Codex Health")
                .menu(&menu)
                .on_menu_event(|app, e| {
                    let handle = app.clone();
                    match e.id.as_ref() {
                        "show" => {
                            tauri::async_runtime::spawn(async move {
                                let _ = show_dashboard(handle).await;
                            });
                        }
                        "floating" => {
                            tauri::async_runtime::spawn(async move {
                                let visible =
                                    !handle.state::<AppState>().preferences().floating_enabled;
                                let _ = toggle_floating(handle, visible).await;
                            });
                        }
                        "quit" => app.exit(0),
                        _ => {}
                    }
                })
                .on_tray_icon_event(|tray, e| {
                    if matches!(
                        e,
                        TrayIconEvent::Click {
                            button: MouseButton::Left,
                            button_state: MouseButtonState::Up,
                            ..
                        }
                    ) {
                        let app = tray.app_handle().clone();
                        tauri::async_runtime::spawn(async move {
                            let _ = show_dashboard(app).await;
                        });
                    }
                })
                .build(app)?;
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                handle.state::<AppState>().apply_native_preferences(&handle);
                restore_floating(&handle);
            });
            AppState::start(app.handle().clone());
            Ok(())
        })
        .on_window_event(|window, event| {
            let app = window.app_handle().clone();
            let Some(state) = app.try_state::<AppState>() else {
                return;
            };
            match event {
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    api.prevent_close();
                    let label = window.label().to_owned();
                    if label == "main" {
                        state.data.lock().unwrap().main_visible = false;
                        state.signal(false, false);
                    }
                    let _ = window.hide();
                    let _ = app.emit_to(window.label(), "visibility-changed", false);
                    if label == "floating" {
                        let handle = app.clone();
                        tauri::async_runtime::spawn(async move {
                            let _ = toggle_floating(handle, false).await;
                        });
                    }
                }
                tauri::WindowEvent::Focused(focused) if window.label() == "main" => {
                    state.data.lock().unwrap().focused = *focused;
                    state.signal(false, false);
                }
                tauri::WindowEvent::ThemeChanged(theme) => {
                    if state.preferences().appearance == "system" {
                        let dark = *theme == tauri::Theme::Dark;
                        let handle = app.clone();
                        tauri::async_runtime::spawn(async move {
                            handle.state::<AppState>().apply_icons(&handle, dark);
                        });
                    }
                }
                _ => {}
            }
        })
        .run(tauri::generate_context!())
        .expect("Codex Health 启动失败");
}
