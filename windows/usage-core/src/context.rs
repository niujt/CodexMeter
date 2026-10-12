use base64::Engine;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, io::Write, path::Path};
pub fn digest(value: &[u8]) -> String {
    format!("{:x}", Sha256::digest(value))
}
pub fn write_json(path: &Path, value: &impl Serialize) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(value).map_err(std::io::Error::other)?;
    if fs::read(path).is_ok_and(|old| old == bytes) {
        return Ok(());
    }
    fs::create_dir_all(
        path.parent()
            .ok_or_else(|| std::io::Error::other("No parent"))?,
    )?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp = path.with_extension(format!("{}.{}.tmp", std::process::id(), stamp));
    let mut file = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temp)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    drop(file);
    fs::rename(temp, path)
}
// Secrets never derive Serialize, Debug, or cross the webview IPC boundary.
pub struct Credentials {
    pub token: String,
    pub account_id: String,
    pub identity: String,
    pub revision: String,
    pub modified_at: DateTime<Utc>,
}
pub fn credentials(root: &Path) -> Option<Credentials> {
    if !root.join("sessions").is_dir() && !root.join("archived_sessions").is_dir() {
        return None;
    }
    let path = root.join("auth.json");
    let metadata = fs::metadata(&path).ok()?;
    if !metadata.is_file() || metadata.len() > 1_048_576 {
        return None;
    }
    let bytes = fs::read(path).ok()?;
    let auth: Value = serde_json::from_slice(&bytes).ok()?;
    if auth["auth_mode"].as_str().is_some_and(|v| v != "chatgpt")
        || auth["OPENAI_API_KEY"]
            .as_str()
            .is_some_and(|v| !v.is_empty())
    {
        return None;
    }
    let token = auth["tokens"]["access_token"].as_str()?.to_owned();
    let account = auth["tokens"]["account_id"].as_str()?.to_owned();
    if token.is_empty() || account.is_empty() {
        return None;
    }
    let subject = auth["tokens"]["id_token"]
        .as_str()
        .and_then(jwt_subject)
        .or_else(|| jwt_subject(&token))
        .unwrap_or_else(|| digest(token.as_bytes()));
    let modified_at = DateTime::<Utc>::from(metadata.modified().ok()?);
    Some(Credentials {
        identity: digest(format!("{}\0{}", account, subject).as_bytes()),
        revision: digest(&bytes),
        modified_at,
        token,
        account_id: account,
    })
}
fn jwt_subject(token: &str) -> Option<String> {
    let part = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(part.trim_end_matches('='))
        .ok()?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    Some(value["sub"].as_str()?.into())
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AccountRecord {
    pub account: Option<String>,
    pub since: DateTime<Utc>,
    pub revision: Option<String>,
}
pub fn resolve(
    prior: Option<&AccountRecord>,
    auth: Option<&Credentials>,
    now: DateTime<Utc>,
    initial: bool,
) -> AccountRecord {
    let account = auth.map(|a| a.identity.clone());
    let revision = auth.map(|a| a.revision.clone());
    let since = match prior {
        Some(p) if p.account == account => {
            if initial && p.revision != revision {
                p.since.max(auth.map_or(now, |a| a.modified_at))
            } else {
                p.since
            }
        }
        Some(_) => now,
        None => auth.map_or(now, |a| a.modified_at),
    };
    AccountRecord {
        account,
        since,
        revision,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn login_change_bounds_quota_and_refresh_preserves_boundary() {
        let now = Utc::now();
        let c = Credentials {
            token: "SECRET".into(),
            account_id: "account".into(),
            identity: "one".into(),
            revision: "r1".into(),
            modified_at: now - chrono::Duration::hours(1),
        };
        let first = resolve(None, Some(&c), now, true);
        assert_eq!(first.since, c.modified_at);
        let mut refresh = c;
        refresh.revision = "r2".into();
        assert_eq!(
            resolve(Some(&first), Some(&refresh), now, false).since,
            first.since
        );
        refresh.identity = "two".into();
        assert_eq!(resolve(Some(&first), Some(&refresh), now, false).since, now);
        assert!(!serde_json::to_string(&first).unwrap().contains("SECRET"));
    }
}
