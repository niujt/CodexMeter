use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
pub mod context;
pub mod forecast;
mod reader;
#[cfg(test)]
use reader::parse;
pub use reader::Reader;

#[derive(Clone, Default, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Tokens {
    pub input: u64,
    pub cached_input: u64,
    pub output: u64,
    pub reasoning_output: u64,
    pub total: u64,
}
impl Tokens {
    fn from(v: &Value) -> Self {
        let n = |k| v[k].as_u64().unwrap_or(0);
        Self {
            input: n("input_tokens"),
            cached_input: n("cached_input_tokens"),
            output: n("output_tokens"),
            reasoning_output: n("reasoning_output_tokens"),
            total: n("total_tokens"),
        }
    }
    fn delta(&self, previous: &Self) -> Self {
        if self.total < previous.total {
            return self.clone();
        }
        Self {
            input: self.input.saturating_sub(previous.input),
            cached_input: self.cached_input.saturating_sub(previous.cached_input),
            output: self.output.saturating_sub(previous.output),
            reasoning_output: self
                .reasoning_output
                .saturating_sub(previous.reasoning_output),
            total: self.total.saturating_sub(previous.total),
        }
    }
    fn add(&mut self, other: &Self) {
        self.input = self.input.saturating_add(other.input);
        self.cached_input = self.cached_input.saturating_add(other.cached_input);
        self.output = self.output.saturating_add(other.output);
        self.reasoning_output = self.reasoning_output.saturating_add(other.reasoning_output);
        self.total = self.total.saturating_add(other.total);
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Rate {
    pub used_percent: f64,
    pub window_minutes: u64,
    pub resets_at: DateTime<Utc>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Event {
    at: DateTime<Utc>,
    project: String,
    model: String,
    usage: Tokens,
    cycle: Option<(String, DateTime<Utc>)>,
    cache_input: Option<(u64, u64)>,
    context_used: u64,
    context_limit: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Quota {
    at: DateTime<Utc>,
    canonical: bool,
    model: String,
    id: String,
    rate: Rate,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReplySample {
    pub completed_at: DateTime<Utc>,
    pub output_tokens: u64,
    pub turn_seconds: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Turn {
    at: DateTime<Utc>,
    project: String,
    model: String,
    seconds: f64,
}
#[derive(Clone, Default, Debug, Serialize, Deserialize)]
pub(crate) struct Summary {
    events: Vec<Event>,
    quotas: Vec<Quota>,
    turns: Vec<Turn>,
    replies: Vec<ReplySample>,
    context_used: u64,
    context_limit: u64,
    malformed: usize,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Day {
    pub date: String,
    pub tokens: u64,
}
#[derive(Clone, Default, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Ranked {
    pub name: String,
    pub tokens: u64,
    pub sessions: usize,
    pub requests: usize,
    pub average_turn_seconds: Option<f64>,
    pub cache_hit_rate: Option<f64>,
    pub last_active: Option<DateTime<Utc>>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub date: DateTime<Utc>,
    pub project: String,
    pub model: String,
    pub tokens: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RateCycle {
    pub date: DateTime<Utc>,
    pub used_percent: f64,
    pub resets_at: DateTime<Utc>,
    pub limit_id: String,
    pub tokens: u64,
}
#[derive(Clone, Default, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReadStats {
    pub parsed_files: usize,
    pub reused_files: usize,
    pub incremental_files: usize,
    pub bytes_read: u64,
    pub persisted_summaries: usize,
    pub aggregate_builds: usize,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub all_time: Tokens,
    pub today: Tokens,
    pub last_seven_days: Tokens,
    pub this_month: Tokens,
    pub daily_usage: Vec<Day>,
    pub hourly_usage: Vec<Day>,
    pub projects: Vec<Ranked>,
    pub today_projects: Vec<Ranked>,
    pub month_projects: Vec<Ranked>,
    pub models: Vec<Ranked>,
    pub records: Vec<Record>,
    pub seven_day_rate: Option<Rate>,
    pub primary_rate: Option<Rate>,
    pub spark_rate: Option<Rate>,
    pub reply_speed_samples: Vec<ReplySample>,
    pub rate_timeline: Vec<RateCycle>,
    pub quota_samples: Vec<RateCycle>,
    pub prediction: forecast::Prediction,
    pub current_context_used: u64,
    pub context_window: u64,
    pub last_updated: Option<DateTime<Utc>>,
    pub observed_at: DateTime<Utc>,
    pub main_rate_sampled_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub primary_rate_sampled_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub spark_rate_sampled_at: Option<DateTime<Utc>>,
    pub file_count: usize,
    pub session_count: usize,
    pub data_path: String,
    pub warnings: Vec<String>,
    pub read_stats: ReadStats,
    pub account_status: String,
    pub quota_waiting_message: String,
    pub context_id: String,
}
#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    fn line(total: u64, date: &str) -> String {
        serde_json::json!({"type":"event_msg","timestamp":date,"payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":total,"input_tokens":total}}}}).to_string()
    }
    #[test]
    fn cumulative_duplicate_and_reset() {
        let input = [
            line(100, "2026-10-06T01:00:00Z"),
            line(100, "2026-10-06T01:01:00Z"),
            line(150, "2026-10-07T01:00:00Z"),
            line(20, "2026-10-07T01:01:00Z"),
        ]
        .join("\n");
        let s = parse(input.as_bytes());
        assert_eq!(
            s.events.iter().map(|e| e.usage.total).collect::<Vec<_>>(),
            vec![100, 0, 50, 20]
        );
    }
    #[test]
    fn malformed_and_private_text_ignored() {
        let input=format!("{{bad}}\n{{\"type\":\"response_item\",\"payload\":{{\"content\":\"private prompt\"}}}}\n{}",line(12,"2026-10-07T00:00:00Z"));
        let s = parse(input.as_bytes());
        assert_eq!(s.malformed, 1);
        assert_eq!(s.events.len(), 1);
        assert_eq!(s.events[0].usage.total, 12);
    }
    #[test]
    fn component_reset_saturates() {
        let a = Tokens {
            total: 120,
            input: 70,
            output: 50,
            ..Tokens::default()
        };
        let b = Tokens {
            total: 100,
            input: 80,
            output: 20,
            ..Tokens::default()
        };
        assert_eq!(a.delta(&b).input, 0);
        assert_eq!(a.delta(&b).output, 30);
    }
    #[test]
    fn canonical_expired_never_falls_back_and_directory_cache_isolated() {
        let root = std::env::temp_dir().join(format!(
            "codex-health-fixture-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let other = root.join("other");
        std::fs::create_dir_all(root.join("sessions")).unwrap();
        std::fs::create_dir_all(other.join("sessions")).unwrap();
        let now = Utc::now();
        let day = now.to_rfc3339();
        let quota = |id: &str, reset: i64, at: String| {
            serde_json::json!({"type":"event_msg","timestamp":at,"payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}},"rate_limits":{"limit_id":id,"secondary":{"used_percent":42,"window_minutes":10080,"resets_at":reset}}}}).to_string()
        };
        let fixture = [
            line(80, &(now - Duration::days(7)).to_rfc3339()),
            line(100, &day),
            quota("codex", now.timestamp() - 1, day.clone()),
            quota(
                "other",
                now.timestamp() + 1000,
                (now + Duration::seconds(1)).to_rfc3339(),
            ),
        ]
        .join("\n");
        std::fs::write(root.join("sessions/sample.jsonl"), fixture).unwrap();
        let mut reader = Reader::default();
        let snap = reader.load(&root, now + Duration::seconds(2)).unwrap();
        assert_eq!(snap.last_seven_days.total, 20);
        assert_eq!(snap.daily_usage.len(), 7);
        assert!(snap.seven_day_rate.is_none());
        let again = reader.load(&root, now + Duration::seconds(2)).unwrap();
        assert_eq!(again.last_seven_days, snap.last_seven_days);
        let empty = reader.load(&other, now).unwrap();
        assert_eq!(empty.last_seven_days.total, 0);
        assert!(empty.last_updated.is_none());
    }
}
