use chrono::{DateTime, Duration, Utc};
use codex_health_usage::context::{digest, write_json};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
};

pub const HOOK_MARKER: &str = "--codex-health-permission-hook";
#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PermissionEvent {
    pub event_id: String,
    pub received_at: DateTime<Utc>,
    pub session_id: String,
    pub turn_id: String,
    pub project: String,
    pub tool_name: String,
    pub mode: String,
    pub model: String,
    pub attention: String,
    pub status: String,
}
fn safe(v: &Value, field: &str, fallback: &str) -> String {
    v[field]
        .as_str()
        .unwrap_or(fallback)
        .chars()
        .filter(|c| !c.is_control())
        .take(500)
        .collect()
}
pub fn sanitize(v: &Value, now: DateTime<Utc>) -> PermissionEvent {
    let reviewer = v["approvals_reviewer"].as_str().or(v["reviewer"].as_str());
    let attention = if v["requires_user_input"] == true || reviewer == Some("user") {
        "human"
    } else if reviewer == Some("auto_review") || v["permission_mode"] == "bypassPermissions" {
        "info"
    } else {
        "possible"
    };
    let id = safe(v, "event_id", "");
    PermissionEvent {
        event_id: if id.is_empty() {
            digest(
                format!(
                    "{}:{}:{}",
                    now.timestamp_nanos_opt().unwrap_or(0),
                    std::process::id(),
                    safe(v, "session_id", "")
                )
                .as_bytes(),
            )
        } else {
            id
        },
        received_at: now,
        session_id: safe(v, "session_id", "unknown"),
        turn_id: safe(v, "turn_id", "unknown"),
        project: safe(v, "cwd", "未归属路径"),
        tool_name: safe(v, "tool_name", "unknown"),
        mode: safe(v, "permission_mode", "default"),
        model: safe(v, "model", "unknown"),
        attention: attention.into(),
        status: "new".into(),
    }
}
pub fn handle_hook(spool: &Path) {
    // Silent and fail-open: the helper never makes an allow/deny decision.
    let mut bytes = Vec::new();
    if std::io::stdin()
        .take(1_048_577)
        .read_to_end(&mut bytes)
        .is_err()
        || bytes.len() > 1_048_576
    {
        return;
    }
    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
        return;
    };
    if !value.is_object() {
        return;
    }
    let event = sanitize(&value, Utc::now());
    let file = spool.join(format!("{}.json", digest(event.event_id.as_bytes())));
    let _ = write_json(&file, &event);
}
pub fn spool(config: &Path, root: &Path) -> PathBuf {
    config
        .join("permissions")
        .join(digest(root.to_string_lossy().as_bytes()))
        .join("spool")
}
fn hooks(root: &Path) -> Result<Value, String> {
    let path = root.join("hooks.json");
    let mut value = if path.exists() {
        if fs::metadata(&path)
            .map_err(|_| "无法读取 hooks.json")?
            .len()
            > 1_048_576
        {
            return Err("hooks.json 过大，未修改".into());
        }
        serde_json::from_slice(&fs::read(path).map_err(|_| "无法读取 hooks.json")?)
            .map_err(|_| "hooks.json 不是有效 JSON，未修改")?
    } else {
        json!({})
    };
    if !value.is_object() {
        return Err("hooks.json 结构无法安全合并".into());
    }
    if value.get("hooks").is_none() {
        value["hooks"] = json!({});
    }
    if !value["hooks"].is_object() {
        return Err("hooks 结构无法安全合并".into());
    }
    if value["hooks"].get("PermissionRequest").is_none() {
        value["hooks"]["PermissionRequest"] = json!([]);
    }
    let groups = value["hooks"]["PermissionRequest"]
        .as_array()
        .ok_or("PermissionRequest 结构无法安全合并")?;
    if groups
        .iter()
        .any(|g| !g.is_object() || g["hooks"].as_array().is_none())
    {
        return Err("已有 Hook 结构无法安全合并，未修改".into());
    }
    Ok(value)
}
fn owned(handler: &Value) -> bool {
    handler["command"]
        .as_str()
        .is_some_and(|s| s.contains(HOOK_MARKER))
}
fn remove_owned(value: &mut Value) {
    if let Some(groups) = value["hooks"]["PermissionRequest"].as_array_mut() {
        for group in groups.iter_mut() {
            if let Some(handlers) = group["hooks"].as_array_mut() {
                handlers.retain(|h| !owned(h));
            }
        }
        groups.retain(|g| g["hooks"].as_array().is_some_and(|a| !a.is_empty()));
    }
}
pub fn status(root: Option<&Path>) -> String {
    let Some(root) = root else {
        return "尚未选择数据目录".into();
    };
    match hooks(root) {
        Ok(v) => if v["hooks"]["PermissionRequest"]
            .as_array()
            .unwrap()
            .iter()
            .any(|g| g["hooks"].as_array().unwrap().iter().any(owned))
        {
            "已安装"
        } else {
            "未安装"
        }
        .into(),
        Err(_) => "配置异常".into(),
    }
}
pub fn install(root: &Path, config: &Path) -> Result<(), String> {
    let mut value = hooks(root)?;
    let executable = std::env::current_exe().map_err(|_| "无法定位应用")?;
    let queue = spool(config, root);
    if [executable.to_string_lossy(), queue.to_string_lossy()]
        .iter()
        .any(|s| s.contains(['"', '\n', '\r', '%']))
    {
        return Err("应用或数据路径包含不支持的命令字符".into());
    }
    let command = format!(
        "\"{}\" {} \"{}\"",
        executable.display(),
        HOOK_MARKER,
        queue.display()
    );
    remove_owned(&mut value);
    value["hooks"]["PermissionRequest"].as_array_mut().unwrap().push(json!({"matcher":"*","hooks":[{"type":"command","command":command,"async":true,"timeout":3}]}));
    write_hooks(root, &value)?;
    fs::create_dir_all(queue).map_err(|_| "无法创建权限提醒队列".to_string())
}
pub fn uninstall(root: &Path) -> Result<(), String> {
    let mut value = hooks(root)?;
    remove_owned(&mut value);
    write_hooks(root, &value)
}
fn write_hooks(root: &Path, value: &Value) -> Result<(), String> {
    let path = root.join("hooks.json");
    if path.exists() {
        let backup = root.join(format!(
            "hooks.json.codex-health-backup-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        fs::copy(&path, backup).map_err(|_| "无法备份现有 Hook，未修改")?;
    }
    write_json(&path, value).map_err(|_| "无法保存 Hook 配置".to_string())
}
pub fn maintain(events: &mut Vec<PermissionEvent>, hours: u64, now: DateTime<Utc>) -> bool {
    let before = events.clone();
    for event in events.iter_mut() {
        if event.status == "new" && event.received_at + Duration::minutes(5) <= now {
            event.status = "expired".into();
        }
    }
    events.retain(|e| {
        if hours == 0 {
            e.status == "new"
        } else {
            e.received_at + Duration::hours(hours as i64) > now
        }
    });
    events.sort_by(|a, b| b.received_at.cmp(&a.received_at));
    events.truncate(500);
    *events != before
}
pub fn next_deadline(
    events: &[PermissionEvent],
    hours: u64,
    now: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    events
        .iter()
        .flat_map(|e| {
            let mut deadlines = vec![];
            if e.status == "new" {
                deadlines.push(e.received_at + Duration::minutes(5));
            }
            if hours > 0 {
                deadlines.push(e.received_at + Duration::hours(hours as i64));
            }
            deadlines
        })
        .filter(|d| *d > now)
        .min()
}
pub fn read_spool(
    queue: &Path,
    events: &mut Vec<PermissionEvent>,
) -> (Vec<PermissionEvent>, Vec<PathBuf>) {
    let mut new = vec![];
    let mut consumed = vec![];
    let Ok(entries) = fs::read_dir(queue) else {
        return (new, consumed);
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "json")
            || fs::symlink_metadata(&path).map_or(true, |m| {
                !m.is_file() || m.file_type().is_symlink() || m.len() > 262144
            })
        {
            continue;
        }
        if let Ok(event) = fs::read(&path).and_then(|b| {
            serde_json::from_slice::<PermissionEvent>(&b).map_err(std::io::Error::other)
        }) {
            if !events.iter().any(|e| e.event_id == event.event_id) {
                events.push(event.clone());
                new.push(event);
            }
            consumed.push(path);
        }
    }
    (new, consumed)
}
pub fn acknowledge_spool(consumed: &[PathBuf]) {
    for path in consumed {
        let _ = fs::remove_file(path);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn helper_never_retains_input_or_credentials() {
        let event = sanitize(
            &json!({"tool_name":"Bash","tool_input":{"command":"PRIVATE"},"access_token":"SECRET","cwd":"C:/project","approvals_reviewer":"auto_review"}),
            Utc::now(),
        );
        let bytes = serde_json::to_string(&event).unwrap();
        assert!(!bytes.contains("PRIVATE") && !bytes.contains("SECRET"));
        assert_eq!(event.attention, "info");
    }
    #[test]
    fn empty_events_have_no_timer() {
        assert!(next_deadline(&[], 24, Utc::now()).is_none());
    }
    #[test]
    fn uninstall_preserves_other_handlers_and_events() {
        let external = json!({"type":"command","command":"other-tool --listen"});
        let mut hooks = json!({"otherSetting":true,"hooks":{
            "PermissionRequest":[{"matcher":"Bash","hooks":[external.clone(),{"type":"command","command":format!("app {} spool",HOOK_MARKER)}]}],
            "Stop":[{"hooks":[external.clone()]}]
        }});
        remove_owned(&mut hooks);
        assert_eq!(
            hooks["hooks"]["PermissionRequest"][0]["hooks"],
            json!([external.clone()])
        );
        assert_eq!(hooks["hooks"]["PermissionRequest"][0]["matcher"], "Bash");
        assert_eq!(hooks["hooks"]["Stop"][0]["hooks"][0], external);
        assert_eq!(hooks["otherSetting"], true);
    }
    #[test]
    fn expires_only_at_deadline() {
        let now = Utc::now();
        let mut events = vec![sanitize(&json!({}), now)];
        assert!(!maintain(&mut events, 24, now + Duration::seconds(299)));
        assert!(maintain(&mut events, 24, now + Duration::seconds(300)));
        assert_eq!(events[0].status, "expired");
    }
}
