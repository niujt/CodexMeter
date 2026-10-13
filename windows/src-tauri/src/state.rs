use crate::permissions::{self, PermissionEvent};
use chrono::{DateTime, Duration, Utc};
use codex_health_usage::{
    context::{self, AccountRecord},
    Reader, Snapshot,
};
use notify::{RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Condvar, Mutex},
    time::Instant,
};
use tauri::{Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct Preferences {
    pub directory: Option<String>,
    pub appearance: String,
    pub icon_style: String,
    pub refresh_interval: u64,
    pub low_rate_threshold: u8,
    pub deduplicate_alerts: bool,
    pub quota_notifications: bool,
    pub permission_enabled: bool,
    pub system_notifications: bool,
    pub badge_enabled: bool,
    pub sound_enabled: bool,
    pub show_preview: bool,
    pub retention_hours: u64,
    pub followed_paths: Vec<String>,
    pub floating_enabled: bool,
    pub floating_style: String,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            directory: None,
            appearance: "system".into(),
            icon_style: "flat".into(),
            refresh_interval: 300,
            low_rate_threshold: 20,
            deduplicate_alerts: true,
            quota_notifications: true,
            permission_enabled: false,
            system_notifications: true,
            badge_enabled: true,
            sound_enabled: true,
            show_preview: false,
            retention_hours: 24,
            followed_paths: vec![],
            floating_enabled: true,
            floating_style: "ball".into(),
        }
    }
}
impl Preferences {
    pub fn validate(&self) -> Result<(), String> {
        if !["system", "light", "dark"].contains(&self.appearance.as_str())
            || !["flat", "glass"].contains(&self.icon_style.as_str())
            || ![300, 900, 1800].contains(&self.refresh_interval)
            || ![5, 10, 20, 30, 50].contains(&self.low_rate_threshold)
            || ![0, 1, 24, 72].contains(&self.retention_hours)
            || !["ball", "summary"].contains(&self.floating_style.as_str())
            || self.followed_paths.len() > 200
        {
            return Err("设置值无效".into());
        }
        Ok(())
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct Saved {
    prefs: Preferences,
    accounts: BTreeMap<String, AccountRecord>,
    alerts: BTreeMap<String, DateTime<Utc>>,
}
pub struct Data {
    saved: Saved,
    pub snapshot: Option<Snapshot>,
    events: Vec<PermissionEvent>,
    source: Option<PathBuf>,
    pub focused: bool,
    pub main_visible: bool,
    last_check: Option<Instant>,
}
#[derive(Default)]
struct Work {
    usage: bool,
    permissions: bool,
    reschedule: bool,
}
pub struct AppState {
    pub data: Mutex<Data>,
    reader: Mutex<Reader>,
    work: Mutex<Work>,
    wake: Condvar,
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
    pub config: PathBuf,
    applied_icon: Mutex<Option<(String, bool)>>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Bootstrap {
    pub preferences: Preferences,
    pub preferences_saved: bool,
    pub snapshot: Option<Snapshot>,
    pub permissions: Vec<PermissionEvent>,
    pub hook_status: String,
    pub low_power: bool,
    pub main_visible: bool,
    pub floating_visible: bool,
}
impl AppState {
    pub fn new(config: PathBuf, cache: PathBuf) -> Self {
        let saved = std::fs::read(config.join("preferences.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Saved>(&b).ok())
            .filter(|s| s.prefs.validate().is_ok())
            .unwrap_or_default();
        let source = saved.prefs.directory.as_ref().map(PathBuf::from);
        let events = source
            .as_ref()
            .and_then(|root| {
                std::fs::read(
                    permissions::spool(&config, root)
                        .parent()?
                        .join("events.json"),
                )
                .ok()
            })
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Self {
            data: Mutex::new(Data {
                saved,
                snapshot: None,
                events,
                source: None,
                focused: false,
                main_visible: true,
                last_check: None,
            }),
            reader: Mutex::new(Reader::with_cache(cache.join("usage-summaries"))),
            work: Mutex::default(),
            wake: Condvar::new(),
            watcher: Mutex::new(None),
            config,
            applied_icon: Mutex::new(None),
        }
    }
    fn save(&self, data: &Data) -> Result<(), String> {
        context::write_json(&self.config.join("preferences.json"), &data.saved)
            .map_err(|_| "无法保存本机设置".into())
    }
    pub fn preferences(&self) -> Preferences {
        self.data.lock().unwrap().saved.prefs.clone()
    }
    pub fn bootstrap(&self, app: &tauri::AppHandle) -> Bootstrap {
        let data = self.data.lock().unwrap();
        Bootstrap {
            preferences: data.saved.prefs.clone(),
            preferences_saved: self.config.join("preferences.json").is_file(),
            snapshot: data.snapshot.clone(),
            permissions: data.events.clone(),
            hook_status: permissions::status(data.saved.prefs.directory.as_ref().map(Path::new)),
            low_power: low_power(),
            main_visible: data.main_visible,
            floating_visible: app
                .get_webview_window("floating")
                .is_some_and(|w| w.is_visible().unwrap_or(false)),
        }
    }
    pub fn signal(&self, usage: bool, permissions: bool) {
        let mut work = self.work.lock().unwrap();
        work.usage |= usage;
        work.permissions |= permissions;
        work.reschedule = true;
        self.wake.notify_one();
    }
    pub fn configure_watcher(&self, app: &tauri::AppHandle) {
        let prefs = self.preferences();
        let Some(root) = prefs.directory.map(PathBuf::from) else {
            *self.watcher.lock().unwrap() = None;
            return;
        };
        let queue = permissions::spool(&self.config, &root);
        if std::fs::create_dir_all(&queue).is_err() {
            return;
        }
        let handle = app.clone();
        let observed = queue.clone();
        if let Ok(mut watcher) =
            notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
                if let Ok(event) = result {
                    if matches!(event.kind, notify::EventKind::Access(_)) {
                        return;
                    }
                    let usage = event
                        .paths
                        .iter()
                        .any(|p| p.file_name().is_some_and(|n| n == "auth.json"));
                    let permissions = event.paths.iter().any(|p| {
                        p.starts_with(&observed) && p.extension().is_some_and(|e| e == "json")
                    });
                    if usage || permissions {
                        if usage {
                            handle
                                .state::<AppState>()
                                .invalidate_changed_account(&handle);
                        }
                        handle.state::<AppState>().signal(usage, permissions);
                    }
                }
            })
        {
            let _ = watcher.watch(&root, RecursiveMode::NonRecursive);
            let _ = watcher.watch(&queue, RecursiveMode::NonRecursive);
            *self.watcher.lock().unwrap() = Some(watcher);
        }
    }
    fn invalidate_changed_account(&self, app: &tauri::AppHandle) {
        let Some(root) = self.preferences().directory.map(PathBuf::from) else {
            return;
        };
        let identity = context::credentials(&root).map(|a| a.identity);
        let mut data = self.data.lock().unwrap();
        let key = context::digest(root.to_string_lossy().as_bytes());
        if data.saved.prefs.directory.as_deref() == Some(root.to_string_lossy().as_ref())
            && data
                .saved
                .accounts
                .get(&key)
                .is_some_and(|prior| prior.account != identity)
        {
            data.snapshot = None;
            let _ = app.emit("usage-invalidated", ());
            drop(data);
            self.update_tray(app);
        }
    }
    pub fn select(&self, app: &tauri::AppHandle, path: String) -> Result<(), String> {
        let root = std::fs::canonicalize(path).map_err(|_| "无法访问所选目录")?;
        let name = root.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !root.is_dir()
            || !(root.join("sessions").is_dir()
                || root.join("archived_sessions").is_dir()
                || ["sessions", "archived_sessions"].contains(&name))
        {
            return Err("请选择 Codex 主目录或 sessions / archived_sessions 会话目录".into());
        }
        {
            let mut data = self.data.lock().unwrap();
            data.saved.prefs.directory = Some(root.to_string_lossy().into());
            data.snapshot = None;
            data.last_check = None;
            data.events = std::fs::read(
                permissions::spool(&self.config, &root)
                    .parent()
                    .unwrap()
                    .join("events.json"),
            )
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
            self.save(&data)?;
        }
        let _ = app.emit("usage-invalidated", ());
        let _ = app.emit("preferences-updated", self.preferences());
        let _ = app.emit(
            "permissions-updated",
            self.data.lock().unwrap().events.clone(),
        );
        self.configure_watcher(app);
        self.signal(false, true);
        Ok(())
    }
    pub fn update_preferences(
        &self,
        app: &tauri::AppHandle,
        mut prefs: Preferences,
    ) -> Result<Preferences, String> {
        prefs.validate()?;
        {
            let mut data = self.data.lock().unwrap();
            prefs.directory = data.saved.prefs.directory.clone();
            data.saved.prefs = prefs.clone();
            self.save(&data)?;
        }
        self.apply_native_preferences(app);
        self.signal(false, true);
        let _ = app.emit("preferences-updated", &prefs);
        Ok(prefs)
    }
    pub fn load(&self, app: &tauri::AppHandle, force: bool) -> Result<Snapshot, String> {
        let started = Utc::now();
        let mut reader = self.reader.lock().map_err(|_| "统计状态不可用")?;
        let (root, prior, initial, prefs) = {
            let data = self.data.lock().unwrap();
            let root = data
                .saved
                .prefs
                .directory
                .as_ref()
                .map(PathBuf::from)
                .ok_or("请先选择 Codex 数据目录")?;
            let prior = data
                .saved
                .accounts
                .get(&context::digest(root.to_string_lossy().as_bytes()))
                .cloned();
            let initial = data.source.as_ref() != Some(&root);
            (root, prior, initial, data.saved.prefs.clone())
        };
        let credentials = context::credentials(&root);
        let now = Utc::now();
        let scope = context::resolve(prior.as_ref(), credentials.as_ref(), now, initial);
        let context_id = context::digest(
            format!("{}:{:?}:{}", root.display(), scope.account, scope.since).as_bytes(),
        );
        {
            let mut data = self.data.lock().unwrap();
            if data.saved.prefs.directory.as_deref() != Some(root.to_string_lossy().as_ref()) {
                return Err("目录已切换，请重新刷新".into());
            }
            if !force {
                if let Some(s) = &data.snapshot {
                    if s.context_id == context_id && s.observed_at >= started {
                        return Ok(s.clone());
                    }
                }
            }
            if data
                .snapshot
                .as_ref()
                .is_some_and(|s| s.context_id != context_id)
            {
                data.snapshot = None;
                let _ = app.emit("usage-invalidated", ());
            }
            data.source = Some(root.clone());
            if prior.as_ref() != Some(&scope) {
                data.saved.accounts.insert(
                    context::digest(root.to_string_lossy().as_bytes()),
                    scope.clone(),
                );
                self.save(&data)?;
            }
        }
        let mut snapshot = reader.load_scoped(
            &root,
            now,
            if scope.account.is_some() {
                scope.since
            } else {
                DateTime::<Utc>::MAX_UTC
            },
            force,
        )?;
        // Re-check login after parsing, so unlabelled quotas never cross an account change.
        if context::credentials(&root).map(|a| a.identity) != scope.account {
            self.signal(true, false);
            return Err("读取期间账户发生变化，请等待新账户采样".into());
        }
        snapshot.context_id = context_id.clone();
        snapshot.account_status =
            if !(root.join("sessions").is_dir() || root.join("archived_sessions").is_dir()) {
                "仅会话目录；Token 正常统计，登录额度需选择 Codex 主目录"
            } else if scope.account.is_some() {
                "已识别登录；额度采用登录边界后的本地采样"
            } else {
                "未识别 ChatGPT 账户，额度与预测暂停"
            }
            .into();
        snapshot.quota_waiting_message = if scope.account.is_some() {
            "等待当前账户新采样"
        } else {
            "额度需登录 ChatGPT 账户"
        }
        .into();
        let mut alert = None;
        {
            let mut data = self.data.lock().unwrap();
            if data.saved.prefs.directory.as_deref() != Some(root.to_string_lossy().as_ref()) {
                return Err("目录已切换，请重新刷新".into());
            }
            if prefs.quota_notifications {
                if let Some(rate) = snapshot.seven_day_rate.as_ref().filter(|_| {
                    snapshot
                        .main_rate_sampled_at
                        .is_some_and(|at| at <= now && now - at < Duration::minutes(15))
                }) {
                    let remaining = 100. - rate.used_percent;
                    if remaining < f64::from(prefs.low_rate_threshold)
                        || snapshot.prediction.will_exhaust
                    {
                        let reason = if remaining < f64::from(prefs.low_rate_threshold) {
                            "low"
                        } else {
                            "forecast"
                        };
                        let key = format!(
                            "{}:{}:{}:{}",
                            context_id,
                            rate.resets_at,
                            now.date_naive(),
                            reason
                        );
                        if !prefs.deduplicate_alerts || !data.saved.alerts.contains_key(&key) {
                            alert = Some(format!(
                                "7 天额度剩余 {:.0}%{}",
                                remaining,
                                if snapshot.prediction.will_exhaust {
                                    "，可能在重置前耗尽"
                                } else {
                                    ""
                                }
                            ));
                            data.saved.alerts.insert(key, now);
                            data.saved
                                .alerts
                                .retain(|_, at| *at > now - Duration::days(30));
                            self.save(&data)?;
                        }
                    }
                }
            }
            data.snapshot = Some(snapshot.clone());
            data.last_check = Some(Instant::now());
        }
        if let Some(body) = alert {
            let _ = app
                .notification()
                .builder()
                .title("Codex Health · 额度提醒")
                .body(body)
                .sound(if prefs.sound_enabled {
                    "Default"
                } else {
                    "None"
                })
                .show();
        }
        let _ = app.emit("usage-updated", &snapshot);
        self.update_tray(app);
        self.signal(false, false);
        Ok(snapshot)
    }
    pub fn maintain_permissions(&self, app: &tauri::AppHandle) {
        let prefs = self.preferences();
        let Some(root) = prefs.directory.as_ref().map(PathBuf::from) else {
            return;
        };
        let queue = permissions::spool(&self.config, &root);
        let mut notifications = vec![];
        {
            let mut data = self.data.lock().unwrap();
            let before = data.events.clone();
            let (new, consumed) = permissions::read_spool(&queue, &mut data.events);
            permissions::maintain(&mut data.events, prefs.retention_hours, Utc::now());
            if before != data.events {
                let history = if prefs.retention_hours == 0 {
                    vec![]
                } else {
                    data.events.clone()
                };
                if context::write_json(&queue.parent().unwrap().join("events.json"), &history)
                    .is_err()
                {
                    return;
                }
                if prefs.permission_enabled && prefs.system_notifications {
                    notifications = new
                        .into_iter()
                        .filter(|e| {
                            e.attention != "info"
                                && e.received_at + Duration::minutes(5) > Utc::now()
                        })
                        .collect();
                }
                let _ = app.emit("permissions-updated", &data.events);
            }
            permissions::acknowledge_spool(&consumed);
        }
        // Coalesce bursts into one generic, non-sensitive notification.
        if !notifications.is_empty() {
            let body = if prefs.show_preview && notifications.len() == 1 {
                format!(
                    "{} · {}",
                    project_name(&notifications[0].project),
                    notifications[0].tool_name
                )
            } else {
                format!("{} 条权限请求可能需要关注", notifications.len())
            };
            let _ = app
                .notification()
                .builder()
                .title("Codex Health · 权限提醒")
                .body(body)
                .sound(if prefs.sound_enabled {
                    "Default"
                } else {
                    "None"
                })
                .show();
        }
        self.update_tray(app);
    }
    pub fn mark_permissions(
        &self,
        app: &tauri::AppHandle,
        id: Option<String>,
        status: &str,
    ) -> Result<(), String> {
        let prefs = self.preferences();
        let mut data = self.data.lock().unwrap();
        if status == "clear" {
            data.events.clear();
        } else {
            for event in &mut data.events {
                if id.as_ref().is_none_or(|id| id == &event.event_id) {
                    event.status = status.into();
                }
            }
        }
        if let Some(root) = prefs.directory.as_ref().map(PathBuf::from) {
            context::write_json(
                &permissions::spool(&self.config, &root)
                    .parent()
                    .unwrap()
                    .join("events.json"),
                &data.events,
            )
            .map_err(|_| "无法保存权限历史")?;
        }
        let _ = app.emit("permissions-updated", &data.events);
        drop(data);
        self.update_tray(app);
        self.signal(false, false);
        Ok(())
    }
    pub fn update_tray(&self, app: &tauri::AppHandle) {
        let data = self.data.lock().unwrap();
        let now = Utc::now();
        let remaining = data
            .snapshot
            .as_ref()
            .and_then(|s| {
                let rate = s.seven_day_rate.as_ref().filter(|r| r.resets_at > now)?;
                let at = s.main_rate_sampled_at.filter(|at| *at <= now)?;
                let label = if now - at >= Duration::minutes(15) {
                    "旧采样 · 上次剩余"
                } else {
                    "本地采样 · 剩余"
                };
                Some(format!(
                    "{} {:.0}% · 采样于 {} · 非实时",
                    label,
                    100. - rate.used_percent,
                    at.with_timezone(&chrono::Local).format("%m-%d %H:%M:%S")
                ))
            })
            .unwrap_or_else(|| "— · 等待额度采样".into());
        let count = data
            .events
            .iter()
            .filter(|e| e.status == "new" && e.attention != "info")
            .count();
        let tooltip = format!(
            "Codex Health · 7 天额度 {}{}",
            remaining,
            if data.saved.prefs.badge_enabled && count > 0 {
                format!(" · 需要关注 {}", count)
            } else {
                String::new()
            }
        );
        drop(data);
        if let Some(tray) = app.tray_by_id("health") {
            let _ = tray.set_tooltip(Some(tooltip));
        }
    }
    pub fn apply_icons(&self, app: &tauri::AppHandle, dark: bool) {
        let prefs = self.preferences();
        let key = (prefs.icon_style.clone(), dark);
        let mut applied = self.applied_icon.lock().unwrap();
        if applied.as_ref() == Some(&key) {
            return;
        }
        let bytes: &[u8] = match (prefs.icon_style.as_str(), dark) {
            ("glass", true) => include_bytes!("../icons/glass-dark.png"),
            ("glass", false) => include_bytes!("../icons/glass-light.png"),
            (_, true) => include_bytes!("../icons/icon-dark.png"),
            _ => include_bytes!("../icons/icon-light.png"),
        };
        if let Ok(image) = tauri::image::Image::from_bytes(bytes) {
            for window in app.webview_windows().values() {
                let _ = window.set_icon(image.clone());
            }
            if let Some(tray) = app.tray_by_id("health") {
                let _ = tray.set_icon(Some(image));
            }
            *applied = Some(key);
        }
    }
    pub fn apply_native_preferences(&self, app: &tauri::AppHandle) {
        let prefs = self.preferences();
        let theme = match prefs.appearance.as_str() {
            "light" => Some(tauri::Theme::Light),
            "dark" => Some(tauri::Theme::Dark),
            _ => None,
        };
        for window in app.webview_windows().values() {
            let _ = window.set_theme(theme);
        }
        if let Some(window) = app.get_webview_window("floating") {
            let (width, height) = if prefs.floating_style == "summary" {
                (300., 300.)
            } else {
                (88., 88.)
            };
            let _ = window.set_size(tauri::LogicalSize::new(width, height));
            if prefs.floating_enabled {
                let _ = window.show();
            } else {
                let _ = window.hide();
            }
            let _ = app.emit_to("floating", "visibility-changed", prefs.floating_enabled);
        }
        let dark = theme.unwrap_or_else(|| {
            app.get_webview_window("main")
                .and_then(|w| w.theme().ok())
                .unwrap_or(tauri::Theme::Light)
        }) == tauri::Theme::Dark;
        self.apply_icons(app, dark);
    }
    pub fn start(app: tauri::AppHandle) {
        std::thread::spawn(move || {
            let state = app.state::<Self>();
            state.configure_watcher(&app);
            state.signal(state.preferences().directory.is_some(), true);
            loop {
                let wait = {
                    let data = state.data.lock().unwrap();
                    let auto = if data.saved.prefs.directory.is_some() {
                        let seconds = effective_interval(
                            data.saved.prefs.refresh_interval,
                            data.focused && data.main_visible,
                            low_power(),
                        );
                        Some(
                            std::time::Duration::from_secs(seconds).saturating_sub(
                                data.last_check
                                    .map_or(std::time::Duration::ZERO, |t| t.elapsed()),
                            ),
                        )
                    } else {
                        None
                    };
                    let maintenance = permissions::next_deadline(
                        &data.events,
                        data.saved.prefs.retention_hours,
                        Utc::now(),
                    )
                    .map(|d| {
                        std::time::Duration::from_millis(
                            (d - Utc::now()).num_milliseconds().max(1) as u64
                        )
                    });
                    match (auto, maintenance) {
                        (Some(a), Some(b)) => Some(a.min(b)),
                        (a, b) => a.or(b),
                    }
                };
                let mut work = state.work.lock().unwrap();
                let timeout;
                if !work.usage && !work.permissions && !work.reschedule {
                    if let Some(wait) = wait {
                        let pair = state.wake.wait_timeout(work, wait).unwrap();
                        work = pair.0;
                        timeout = pair.1.timed_out();
                    } else {
                        work = state.wake.wait(work).unwrap();
                        timeout = false;
                    }
                } else {
                    timeout = false;
                }
                let requested_usage = work.usage;
                let requested_permissions = work.permissions;
                *work = Work::default();
                drop(work);
                if requested_permissions || timeout {
                    std::thread::sleep(std::time::Duration::from_millis(120));
                    state.maintain_permissions(&app);
                }
                let due = {
                    let data = state.data.lock().unwrap();
                    data.saved.prefs.directory.is_some()
                        && data.last_check.is_none_or(|t| {
                            t.elapsed().as_secs()
                                >= effective_interval(
                                    data.saved.prefs.refresh_interval,
                                    data.focused && data.main_visible,
                                    low_power(),
                                )
                        })
                };
                if requested_usage || timeout && due {
                    if let Err(error) = state.load(&app, false) {
                        let _ = app.emit("usage-error", error);
                        let mut data = state.data.lock().unwrap();
                        data.last_check = Some(Instant::now());
                    }
                }
            }
        });
    }
}
fn project_name(path: &str) -> &str {
    path.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
}
pub fn effective_interval(configured: u64, foreground: bool, low_power: bool) -> u64 {
    configured.max(300).max(if low_power {
        1800
    } else if foreground {
        300
    } else {
        900
    })
}
#[cfg(windows)]
fn low_power() -> bool {
    #[repr(C)]
    struct PowerStatus {
        ac: u8,
        flag: u8,
        percent: u8,
        saver: u8,
        life: u32,
        full: u32,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetSystemPowerStatus(status: *mut PowerStatus) -> i32;
    }
    let mut status = PowerStatus {
        ac: 0,
        flag: 0,
        percent: 0,
        saver: 0,
        life: 0,
        full: 0,
    };
    unsafe {
        GetSystemPowerStatus(&mut status) != 0
            && (status.saver == 1 || status.flag != 255 && status.flag & 6 != 0)
    }
}
#[cfg(not(windows))]
fn low_power() -> bool {
    false
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn background_power_policy_preserves_user_interval() {
        assert_eq!(effective_interval(300, true, false), 300);
        assert_eq!(effective_interval(300, false, false), 900);
        assert_eq!(effective_interval(300, true, true), 1800);
        assert_eq!(effective_interval(3600, false, true), 3600);
    }
    #[test]
    fn bad_preferences_rejected() {
        let mut prefs = Preferences::default();
        prefs.refresh_interval = 1;
        assert!(prefs.validate().is_err());
    }
}
