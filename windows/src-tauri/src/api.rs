use crate::api_credentials as credentials;
use chrono::{DateTime, Datelike, Duration as Days, TimeZone, Utc};
use codex_health_usage::context;
use reqwest::{redirect::Policy, Client, Url};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Mutex,
    time::Duration,
};
use tauri::State;

const INVALID: &str = "官方响应无法识别，未采用本次数据。";
#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq, Ord, PartialOrd)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Openai,
    Deepseek,
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    input: String,
    cached_input: String,
    output: String,
    requests: String,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Limit {
    configured: bool,
    amount: Option<String>,
    enforcing: bool,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Balance {
    currency: String,
    total: String,
    granted: String,
    topped_up: String,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    provider: Provider,
    checked_at: DateTime<Utc>,
    period_start: Option<DateTime<Utc>>,
    costs: Option<BTreeMap<String, String>>,
    usage: Option<Usage>,
    limit: Option<Limit>,
    budget_remaining: Option<String>,
    balances: Option<Vec<Balance>>,
    is_available: Option<bool>,
    warnings: Vec<String>,
}
impl Snapshot {
    fn empty(provider: Provider, now: DateTime<Utc>) -> Self {
        Self {
            provider,
            checked_at: now,
            period_start: None,
            costs: None,
            usage: None,
            limit: None,
            budget_remaining: None,
            balances: None,
            is_available: None,
            warnings: vec![],
        }
    }
}
#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    configured: bool,
    snapshot: Option<Snapshot>,
    error: Option<String>,
    busy: bool,
}
#[derive(Default)]
struct Slot {
    fingerprint: Option<String>,
    generation: u64,
    last_attempt: Option<DateTime<Utc>>,
    status: Status,
}
#[derive(Default)]
pub struct ApiState {
    slots: Mutex<BTreeMap<Provider, Slot>>,
}
impl ApiState {
    fn with_slot<T>(
        &self,
        provider: Provider,
        f: impl FnOnce(&mut Slot) -> T,
    ) -> Result<T, String> {
        let mut slots = self.slots.lock().map_err(|_| "API 状态暂时不可用。")?;
        Ok(f(slots.entry(provider).or_default()))
    }
    fn identify(&self, provider: Provider, key: Option<&str>) -> Result<Status, String> {
        let fingerprint = key.map(|s| context::digest(s.as_bytes()));
        self.with_slot(provider, |slot| {
            if slot.fingerprint != fingerprint {
                slot.generation = slot.generation.wrapping_add(1);
                slot.status = Status::default();
                slot.last_attempt = None;
                slot.fingerprint = fingerprint;
            }
            slot.status.configured = key.is_some();
            slot.status.clone()
        })
    }
    fn begin(
        &self,
        provider: Provider,
        now: DateTime<Utc>,
        force: bool,
    ) -> Result<(u64, Status, bool), String> {
        self.with_slot(provider, |slot| {
            let fresh = slot
                .last_attempt
                .is_some_and(|date| date <= now && now - date < Days::minutes(5))
                && slot.status.snapshot.as_ref().is_some_and(|s| {
                    provider == Provider::Deepseek || s.period_start == Some(month_start(now))
                });
            if slot.status.busy || (!force && fresh) {
                return (slot.generation, slot.status.clone(), false);
            }
            slot.status.busy = true;
            slot.status.error = None;
            slot.last_attempt = Some(now);
            (slot.generation, slot.status.clone(), true)
        })
    }
    fn finish(
        &self,
        provider: Provider,
        generation: u64,
        result: Result<Snapshot, String>,
    ) -> Result<Status, String> {
        self.with_slot(provider, |slot| {
            if slot.generation != generation {
                return Err("密钥已变化，已丢弃旧账户结果，请重新刷新。".to_string());
            }
            slot.status.busy = false;
            match result {
                Ok(snapshot) => {
                    slot.status.snapshot = Some(snapshot);
                    slot.status.error = None;
                }
                Err(error) => slot.status.error = Some(error),
            }
            Ok(slot.status.clone())
        })?
    }
}

fn main_window(window: &tauri::WebviewWindow) -> Result<(), String> {
    if window.label() == "main" {
        Ok(())
    } else {
        Err("请在主窗口配置或查询 API。".into())
    }
}
#[tauri::command]
pub fn api_open_console(window: tauri::WebviewWindow, provider: Provider) -> Result<(), String> {
    main_window(&window)?;
    let url = match provider {
        Provider::Openai => "https://platform.openai.com/settings/organization/billing/overview",
        Provider::Deepseek => "https://platform.deepseek.com/",
    };
    #[cfg(windows)]
    std::process::Command::new("explorer.exe")
        .arg(url)
        .spawn()
        .map_err(|_| "无法打开官方控制台。")?;
    #[cfg(not(windows))]
    let _ = url;
    Ok(())
}
#[tauri::command]
pub fn api_status(
    window: tauri::WebviewWindow,
    state: State<'_, ApiState>,
    provider: Provider,
) -> Result<Status, String> {
    main_window(&window)?;
    let key = credentials::read(provider)?;
    state.identify(provider, key.as_deref())
}
#[tauri::command]
pub fn api_save_key(
    window: tauri::WebviewWindow,
    state: State<'_, ApiState>,
    provider: Provider,
    text: String,
) -> Result<Status, String> {
    main_window(&window)?;
    let key = credentials::extract(&text)?;
    credentials::save(provider, &key)?;
    // Invalidate even when the saved key is unchanged, so a user-requested reconnect is fresh.
    state.identify(provider, None)?;
    state.identify(provider, Some(&key))
}
#[tauri::command]
pub async fn api_load(
    window: tauri::WebviewWindow,
    state: State<'_, ApiState>,
    provider: Provider,
    force: bool,
) -> Result<Status, String> {
    main_window(&window)?;
    let key = credentials::read(provider)?;
    let status = state.identify(provider, key.as_deref())?;
    let Some(key) = key else {
        return Ok(status);
    };
    let now = Utc::now();
    let (generation, status, run) = state.begin(provider, now, force)?;
    if !run {
        return Ok(status);
    }
    let result = load(provider, &key, now).await;
    state.finish(provider, generation, result)
}

fn month_start(now: DateTime<Utc>) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
        .unwrap()
}
fn query_end(now: DateTime<Utc>) -> DateTime<Utc> {
    (now.date_naive() + Days::days(1))
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc()
}
fn decimal(value: &str) -> Result<Decimal, String> {
    let s = value.strip_prefix('-').unwrap_or(value);
    let parts: Vec<_> = s.split('.').collect();
    if parts.is_empty()
        || parts.len() > 2
        || parts
            .iter()
            .any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(INVALID.into());
    }
    Decimal::from_str_exact(value).map_err(|_| INVALID.into())
}
fn status_error(status: u16, body: &Value, scope: &str) -> String {
    if status == 401 {
        return "密钥无效或已过期，请在设置中重新配置。".into();
    }
    let message = body
        .get("error")
        .and_then(|e| {
            e.as_str()
                .or_else(|| e.get("message").and_then(Value::as_str))
        })
        .unwrap_or("");
    if status == 403
        && !scope.is_empty()
        && message.contains("Missing scopes:")
        && message.contains(scope)
    {
        return format!("密钥缺少读取权限：{scope}。请检查 Admin API Key 和组织角色。");
    }
    format!("官方接口返回 HTTP {status}，请稍后重试。")
}
async fn get(client: &Client, url: Url, key: &str) -> Result<(u16, Value), String> {
    let response = client
        .get(url)
        .bearer_auth(key)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|_| "暂时无法连接官方 API，请检查网络后重试。")?;
    let status = response.status().as_u16();
    let bytes = response
        .bytes()
        .await
        .map_err(|_| "无法完整读取官方响应。")?;
    if bytes.len() > 5 * 1024 * 1024 {
        return Err("官方响应超出安全读取范围。".into());
    }
    let body = match serde_json::from_slice(&bytes) {
        Ok(body) => body,
        Err(_) if status != 200 => Value::Null,
        Err(_) => return Err(INVALID.into()),
    };
    Ok((status, body))
}
fn endpoint(path: &str, now: DateTime<Utc>, page: Option<&str>) -> Url {
    let mut url = Url::parse(&format!("https://api.openai.com/v1/organization/{path}")).unwrap();
    if path != "spend_limit" {
        url.query_pairs_mut()
            .append_pair("start_time", &month_start(now).timestamp().to_string())
            .append_pair("end_time", &query_end(now).timestamp().to_string())
            .append_pair("bucket_width", "1d")
            .append_pair("limit", "31");
        if let Some(page) = page {
            url.query_pairs_mut().append_pair("page", page);
        }
    }
    url
}
async fn rows(
    client: &Client,
    path: &str,
    key: &str,
    now: DateTime<Utc>,
) -> Result<Vec<Value>, String> {
    let mut rows = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen = BTreeSet::new();
    for _ in 0..100 {
        let (status, body) = get(client, endpoint(path, now, cursor.as_deref()), key).await?;
        if status != 200 {
            return Err(status_error(status, &body, "api.usage.read"));
        }
        let (values, next) = page_values(&body, &mut seen)?;
        rows.extend(values);
        if next.is_none() {
            return Ok(rows);
        }
        cursor = next;
    }
    Err("分页数据超出范围，未采用本次汇总。".into())
}
fn page_values(
    body: &Value,
    seen: &mut BTreeSet<String>,
) -> Result<(Vec<Value>, Option<String>), String> {
    let mut values = Vec::new();
    for bucket in body.get("data").and_then(Value::as_array).ok_or(INVALID)? {
        values.extend(
            bucket
                .get("results")
                .and_then(Value::as_array)
                .ok_or(INVALID)?
                .iter()
                .cloned(),
        );
    }
    match body.get("has_more").and_then(Value::as_bool) {
        Some(false) => return Ok((values, None)),
        Some(true) => {}
        None => return Err(INVALID.into()),
    }
    let next = body
        .get("next_page")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or("分页数据不完整，未采用本次汇总。")?;
    if !seen.insert(next.to_string()) {
        return Err("分页数据循环，未采用本次汇总。".into());
    }
    Ok((values, Some(next.into())))
}
fn costs(rows: &[Value]) -> Result<BTreeMap<String, String>, String> {
    let mut amounts: BTreeMap<String, Decimal> = BTreeMap::new();
    for row in rows {
        let amount = row.get("amount").ok_or(INVALID)?;
        let currency = amount
            .get("currency")
            .and_then(Value::as_str)
            .ok_or(INVALID)?
            .to_ascii_lowercase();
        if currency.len() != 3 || !currency.bytes().all(|b| b.is_ascii_lowercase()) {
            return Err(INVALID.into());
        }
        let value = amount
            .get("value")
            .filter(|v| v.is_number())
            .ok_or(INVALID)?
            .to_string();
        let value = Decimal::from_str_exact(&value)
            .or_else(|_| Decimal::from_scientific(&value))
            .map_err(|_| INVALID)?;
        let total = amounts.entry(currency).or_default();
        *total = total.checked_add(value).ok_or(INVALID)?;
    }
    Ok(amounts
        .into_iter()
        .map(|(k, v)| (k, v.normalize().to_string()))
        .collect())
}
fn usage(rows: &[Value]) -> Result<Usage, String> {
    let mut totals = [0u64; 4];
    for row in rows {
        let input = row
            .get("input_tokens")
            .and_then(Value::as_u64)
            .ok_or(INVALID)?;
        let cached = match row.get("input_cached_tokens") {
            Some(v) if !v.is_null() => v.as_u64().ok_or(INVALID)?,
            _ => 0,
        };
        if cached > input {
            return Err(INVALID.into());
        }
        for (total, value) in totals.iter_mut().zip([
            input,
            cached,
            row.get("output_tokens")
                .and_then(Value::as_u64)
                .ok_or(INVALID)?,
            row.get("num_model_requests")
                .and_then(Value::as_u64)
                .ok_or(INVALID)?,
        ]) {
            *total = total.checked_add(value).ok_or(INVALID)?;
        }
    }
    Ok(Usage {
        input: totals[0].to_string(),
        cached_input: totals[1].to_string(),
        output: totals[2].to_string(),
        requests: totals[3].to_string(),
    })
}
fn limit(status: u16, body: &Value) -> Result<Limit, String> {
    if status == 404
        && body.pointer("/error/code").and_then(Value::as_str) == Some("not_found")
        && body.pointer("/error/message").and_then(Value::as_str)
            == Some("No organization spend limit is configured.")
    {
        return Ok(Limit {
            configured: false,
            amount: None,
            enforcing: false,
        });
    }
    if status != 200 {
        return Err(status_error(status, body, "api.management.read"));
    }
    if body.get("currency").and_then(Value::as_str) != Some("USD")
        || body.get("interval").and_then(Value::as_str) != Some("month")
    {
        return Err(INVALID.into());
    }
    let enforcing = match body.pointer("/enforcement/status").and_then(Value::as_str) {
        Some("enforcing") => true,
        Some("inactive") => false,
        _ => return Err(INVALID.into()),
    };
    let amount = Decimal::from(
        body.get("threshold_amount")
            .and_then(Value::as_u64)
            .ok_or(INVALID)?,
    ) / Decimal::from(100);
    Ok(Limit {
        configured: true,
        amount: Some(amount.normalize().to_string()),
        enforcing,
    })
}
fn deepseek(body: &Value, now: DateTime<Utc>) -> Result<Snapshot, String> {
    let available = body
        .get("is_available")
        .and_then(Value::as_bool)
        .ok_or(INVALID)?;
    let mut currencies = BTreeSet::new();
    let mut balances = Vec::new();
    for row in body
        .get("balance_infos")
        .and_then(Value::as_array)
        .ok_or(INVALID)?
    {
        let currency = row.get("currency").and_then(Value::as_str).ok_or(INVALID)?;
        if !["CNY", "USD"].contains(&currency) || !currencies.insert(currency) {
            return Err(INVALID.into());
        }
        let money = |field| {
            row.get(field)
                .and_then(Value::as_str)
                .ok_or_else(|| INVALID.to_string())
                .and_then(decimal)
                .map(|v| v.normalize().to_string())
        };
        balances.push(Balance {
            currency: currency.into(),
            total: money("total_balance")?,
            granted: money("granted_balance")?,
            topped_up: money("topped_up_balance")?,
        });
    }
    let mut snapshot = Snapshot::empty(Provider::Deepseek, now);
    snapshot.balances = Some(balances);
    snapshot.is_available = Some(available);
    Ok(snapshot)
}
fn client() -> Result<Client, String> {
    Client::builder()
        .redirect(Policy::none())
        .timeout(Duration::from_secs(25))
        .connect_timeout(Duration::from_secs(10))
        .build()
        .map_err(|_| "无法初始化 API 查询。".into())
}
async fn load(provider: Provider, key: &str, now: DateTime<Utc>) -> Result<Snapshot, String> {
    let client = client()?;
    if provider == Provider::Deepseek {
        let (status, body) = get(
            &client,
            Url::parse("https://api.deepseek.com/user/balance").unwrap(),
            key,
        )
        .await?;
        if status != 200 {
            return Err(status_error(status, &body, ""));
        }
        return deepseek(&body, now);
    }
    let mut snapshot = Snapshot::empty(provider, now);
    snapshot.period_start = Some(month_start(now));
    match rows(&client, "costs", key, now)
        .await
        .and_then(|r| costs(&r))
    {
        Ok(costs) => snapshot.costs = Some(costs),
        Err(e) => snapshot.warnings.push(format!("费用：{e}")),
    }
    match rows(&client, "usage/completions", key, now)
        .await
        .and_then(|r| usage(&r))
    {
        Ok(usage) => snapshot.usage = Some(usage),
        Err(e) => snapshot.warnings.push(format!("Token 用量：{e}")),
    }
    match get(&client, endpoint("spend_limit", now, None), key)
        .await
        .and_then(|(s, b)| limit(s, &b))
    {
        Ok(limit) => snapshot.limit = Some(limit),
        Err(e) => snapshot.warnings.push(format!("消费上限：{e}")),
    }
    if let (Some(costs), Some(limit)) = (&snapshot.costs, &snapshot.limit) {
        if limit.configured && costs.keys().all(|k| k == "usd") {
            if let Some(amount) = &limit.amount {
                let spent = decimal(costs.get("usd").map_or("0", String::as_str))?;
                snapshot.budget_remaining = Some(
                    decimal(amount)?
                        .checked_sub(spent)
                        .ok_or(INVALID)?
                        .max(Decimal::ZERO)
                        .normalize()
                        .to_string(),
                );
            }
        }
    }
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn pagination_rejects_missing_and_repeated_cursors() {
        let mut seen = BTreeSet::new();
        let data = json!({"data":[{"results":[{"amount":{"value":1,"currency":"usd"}}]}],"has_more":true,"next_page":"cursor-A"});
        let (values, next) = page_values(&data, &mut seen).unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(next.as_deref(), Some("cursor-A"));
        assert!(page_values(&data, &mut seen).is_err());
        assert!(page_values(&json!({"data":[],"has_more":true}), &mut BTreeSet::new()).is_err());
        assert!(page_values(&json!({"data":[{}],"has_more":false}), &mut BTreeSet::new()).is_err());
    }
    #[test]
    fn transport_does_not_follow_redirects_or_move_bearer_keys() {
        use std::{
            io::{Read, Write},
            net::TcpListener,
        };
        let server = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = server.local_addr().unwrap();
        let thread = std::thread::spawn(move || {
            let (mut socket, _) = server.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut bytes = Vec::new();
            while !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                let mut chunk = [0u8; 1024];
                let n = socket.read(&mut chunk).unwrap();
                if n == 0 {
                    break;
                }
                bytes.extend_from_slice(&chunk[..n]);
                assert!(bytes.len() <= 4096);
            }
            let request = String::from_utf8_lossy(&bytes);
            assert!(request.starts_with("GET /balance"));
            assert!(request
                .to_ascii_lowercase()
                .contains("authorization: bearer sk-synthetic-test-00000000"));
            socket.write_all(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/never\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
        });
        tauri::async_runtime::block_on(async {
            let (status, _) = get(
                &client().unwrap(),
                Url::parse(&format!("http://{address}/balance")).unwrap(),
                "sk-synthetic-test-00000000",
            )
            .await
            .unwrap();
            assert_eq!(status, 302);
        });
        thread.join().unwrap();
    }
    #[test]
    fn decimal_balance_and_currency_are_preserved() {
        let data = json!({"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00000001","granted_balance":"10.00000001","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"1.2","granted_balance":"0","topped_up_balance":"1.2"}]});
        let s = deepseek(&data, Utc::now()).unwrap();
        assert_eq!(s.balances.as_ref().unwrap()[0].total, "110.00000001");
        assert_eq!(s.balances.unwrap().len(), 2);
        for value in ["NaN", "Infinity", "1x", " 1", "1\n", "1e2", ""] {
            assert!(decimal(value).is_err());
        }
        assert!(deepseek(
            &json!({"is_available":true,"balance_infos":[{"currency":"EUR"}]}),
            Utc::now()
        )
        .is_err());
    }
    #[test]
    fn empty_and_unavailable_balances_are_not_fabricated() {
        let s = deepseek(
            &json!({"is_available":false,"balance_infos":[]}),
            Utc::now(),
        )
        .unwrap();
        assert_eq!(s.is_available, Some(false));
        assert!(s.balances.unwrap().is_empty());
        assert!(deepseek(&json!({}), Utc::now()).is_err());
    }
    #[test]
    fn cost_totals_are_decimal_and_cached_input_is_not_added_twice() {
        let r = costs(&[
            json!({"amount":{"value":0.1,"currency":"usd"}}),
            json!({"amount":{"value":0.2,"currency":"usd"}}),
        ])
        .unwrap();
        assert_eq!(r["usd"], "0.3");
        let u=usage(&[json!({"input_tokens":100,"input_cached_tokens":80,"output_tokens":20,"num_model_requests":2})]).unwrap();
        assert_eq!(u.input, "100");
        assert_eq!(u.cached_input, "80");
        assert!(usage(&[json!({"input_tokens":1,"input_cached_tokens":2,"output_tokens":0,"num_model_requests":1})]).is_err());
    }
    #[test]
    fn only_known_404_means_no_spend_limit() {
        let data = json!({"error":{"code":"not_found","message":"No organization spend limit is configured."}});
        assert!(!limit(404, &data).unwrap().configured);
        assert!(limit(404, &json!({})).is_err());
        assert_eq!(limit(200,&json!({"currency":"USD","interval":"month","threshold_amount":12345,"enforcement":{"status":"enforcing"}})).unwrap().amount.unwrap(),"123.45");
    }
    #[test]
    fn request_bounds_include_current_utc_day_and_escape_cursor() {
        let now = DateTime::parse_from_rfc3339("2026-10-31T23:30:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(query_end(now).to_rfc3339(), "2026-11-01T00:00:00+00:00");
        let url = endpoint("costs", now, Some("next+/page"));
        assert_eq!(url.host_str(), Some("api.openai.com"));
        assert!(url
            .query_pairs()
            .any(|(k, v)| k == "page" && v == "next+/page"));
    }
    #[test]
    fn errors_do_not_expose_server_text_or_confuse_generic_403_with_scopes() {
        let body = json!({"error":"sensitive-token"});
        assert!(!status_error(403, &body, "api.usage.read").contains("sensitive"));
        assert!(status_error(
            403,
            &json!({"error":"Missing scopes: api.usage.read"}),
            "api.usage.read"
        )
        .contains("api.usage.read"));
    }
    #[test]
    fn cache_and_generation_prevent_old_account_results() {
        let state = ApiState::default();
        let now = Utc::now();
        state
            .identify(Provider::Deepseek, Some("synthetic-A"))
            .unwrap();
        let (old, _, run) = state.begin(Provider::Deepseek, now, false).unwrap();
        assert!(run);
        state
            .identify(Provider::Deepseek, Some("synthetic-B"))
            .unwrap();
        assert!(state
            .finish(
                Provider::Deepseek,
                old,
                Ok(Snapshot::empty(Provider::Deepseek, now))
            )
            .is_err());
        let (current, _, _) = state.begin(Provider::Deepseek, now, false).unwrap();
        state
            .finish(
                Provider::Deepseek,
                current,
                Ok(Snapshot::empty(Provider::Deepseek, now)),
            )
            .unwrap();
        assert!(
            !state
                .begin(Provider::Deepseek, now + Days::seconds(60), false)
                .unwrap()
                .2
        );
        assert!(
            state
                .begin(Provider::Deepseek, now + Days::seconds(61), true)
                .unwrap()
                .2
        );
        state
            .finish(Provider::Deepseek, current, Err("network".into()))
            .unwrap();
        let s = state
            .identify(Provider::Deepseek, Some("synthetic-B"))
            .unwrap();
        assert!(s.snapshot.is_some());
        assert_eq!(s.error.as_deref(), Some("network"));
        assert!(!state.identify(Provider::Openai, None).unwrap().configured);
    }
}
