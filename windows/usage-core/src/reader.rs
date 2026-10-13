use crate::*;
use chrono::{Datelike, Duration, Local, Timelike};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::SystemTime,
};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
struct Fingerprint {
    modified: SystemTime,
    created: Option<SystemTime>,
    size: u64,
    identity: u64,
}
fn fingerprint(path: &Path) -> std::io::Result<Fingerprint> {
    let m = fs::metadata(path)?;
    #[cfg(unix)]
    let identity = {
        use std::os::unix::fs::MetadataExt;
        m.ino() ^ m.dev()
    };
    #[cfg(not(unix))]
    let identity = 0;
    Ok(Fingerprint {
        modified: m.modified()?,
        created: m.created().ok(),
        size: m.len(),
        identity,
    })
}
#[derive(Clone, Default, Serialize, Deserialize)]
struct PendingReply {
    start: Option<DateTime<Utc>>,
    completed: Option<DateTime<Utc>>,
    output: u64,
    reliable: bool,
    task: bool,
}
#[derive(Clone, Default, Serialize, Deserialize)]
struct Parser {
    summary: Summary,
    previous: Option<Tokens>,
    has_output: bool,
    has_cache: bool,
    project: String,
    model: String,
    reply: Option<PendingReply>,
    turn: Option<(DateTime<Utc>, String, String)>,
    cycles: BTreeMap<String, (String, DateTime<Utc>)>,
}
impl Parser {
    fn new() -> Self {
        Self {
            project: "未归属路径".into(),
            model: "其他".into(),
            ..Self::default()
        }
    }
    fn finish_reply(&mut self) {
        let Some(p) = self.reply.take() else { return };
        if let (Some(start), Some(end)) = (p.start, p.completed) {
            let seconds = (end - start).num_milliseconds() as f64 / 1000.;
            if p.reliable && p.output > 0 && seconds > 0. && seconds <= 3600. {
                self.summary.replies.push(ReplySample {
                    completed_at: end,
                    output_tokens: p.output,
                    turn_seconds: seconds,
                });
            }
        }
    }
    fn complete_turn(&mut self, at: DateTime<Utc>) {
        if let Some((start, model, project)) = self.turn.take() {
            let seconds = (at - start).num_milliseconds() as f64 / 1000.;
            if (0.0..=3600.).contains(&seconds) {
                self.summary.turns.push(Turn {
                    at,
                    project,
                    model,
                    seconds,
                });
            }
        }
    }
    fn displayed(&self) -> Summary {
        let mut copy = self.clone();
        copy.finish_reply();
        copy.summary
    }
    fn line(&mut self, line: &[u8]) {
        if line.iter().all(u8::is_ascii_whitespace) {
            return;
        }
        let v: Value = match serde_json::from_slice(line) {
            Ok(v) => v,
            Err(_) => {
                self.summary.malformed += 1;
                return;
            }
        };
        let p = &v["payload"];
        let kind = v["type"].as_str().unwrap_or("");
        let ty = p["type"].as_str().unwrap_or("");
        if kind == "session_meta" {
            if let Some(s) = p["cwd"].as_str() {
                self.project = s.into();
            }
        }
        if kind == "turn_context" {
            if let Some(s) = p["model"].as_str() {
                self.model = s.into();
            }
        }
        if kind == "event_msg" && ty == "thread_settings_applied" {
            if let Some(s) = p["thread_settings"]["model"].as_str() {
                self.model = s.into();
            }
        }
        let Some(at) = v["timestamp"]
            .as_str()
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.with_timezone(&Utc))
        else {
            if kind == "event_msg" && ty == "token_count" {
                self.summary.malformed += 1;
            }
            return;
        };
        if kind == "response_item" && ty == "message" {
            if p["role"] == "user" {
                self.turn = Some((at, self.model.clone(), self.project.clone()));
                if !self
                    .reply
                    .as_ref()
                    .is_some_and(|r| r.task && r.completed.is_none())
                {
                    self.finish_reply();
                    self.reply = Some(PendingReply {
                        start: Some(at),
                        reliable: true,
                        ..PendingReply::default()
                    });
                }
            } else if p["role"] == "assistant" && p["phase"] == "final_answer" {
                self.complete_turn(at);
                if let Some(r) = &mut self.reply {
                    r.completed.get_or_insert(at);
                }
            }
        }
        if kind != "event_msg" {
            return;
        }
        match ty {
            "task_started" => {
                self.finish_reply();
                self.reply = Some(PendingReply {
                    start: Some(at),
                    reliable: true,
                    task: true,
                    ..PendingReply::default()
                });
            }
            "task_complete" => {
                self.complete_turn(at);
                if let Some(r) = &mut self.reply {
                    r.completed.get_or_insert(at);
                }
                self.finish_reply();
            }
            "task_aborted" | "turn_aborted" => {
                self.reply = None;
                self.turn = None;
            }
            "token_count" => {
                let limits = &p["rate_limits"];
                let id = limits["limit_id"].as_str().unwrap_or("").to_owned();
                for key in ["primary", "secondary"] {
                    let raw = &limits[key];
                    if let (Some(percent), Some(minutes), Some(reset)) = (
                        raw["used_percent"].as_f64(),
                        raw["window_minutes"].as_u64(),
                        raw["resets_at"].as_i64(),
                    ) {
                        if percent.is_finite() && (0.0..=100.0).contains(&percent) && minutes > 0 {
                            if let Some(end) = DateTime::from_timestamp(reset, 0) {
                                if minutes == 10080 && !is_spark(&self.model) {
                                    self.cycles.insert(self.model.clone(), (id.clone(), end));
                                }
                                self.summary.quotas.push(Quota {
                                    at,
                                    canonical: id.eq_ignore_ascii_case("codex"),
                                    model: self.model.clone(),
                                    id: id.clone(),
                                    rate: Rate {
                                        used_percent: percent,
                                        window_minutes: minutes,
                                        resets_at: end,
                                    },
                                });
                            }
                        }
                    }
                }
                let info = &p["info"];
                let usage = &info["total_token_usage"];
                if info.is_null() {
                    return;
                }
                if !usage.is_object() || usage["total_tokens"].as_u64().is_none() {
                    self.summary.malformed += 1;
                    return;
                }
                let total = Tokens::from(usage);
                let previous = self.previous.as_ref();
                let reset = previous.is_some_and(|old| total.total < old.total);
                let delta = previous.map_or_else(|| total.clone(), |old| total.delta(old));
                let has_output = usage["output_tokens"].as_u64().is_some();
                let first = info["last_token_usage"]["output_tokens"].as_u64()
                    == Some(total.output)
                    && info["last_token_usage"]["total_tokens"].as_u64() == Some(total.total);
                if let Some(r) = &mut self.reply {
                    if r.start.is_some_and(|start| at >= start) {
                        if has_output
                            && (self.has_output && previous.is_some() || first)
                            && (reset || previous.is_none_or(|old| total.output >= old.output))
                        {
                            r.output = r.output.saturating_add(delta.output);
                        } else {
                            r.reliable = false;
                        }
                    }
                }
                let has_cache = usage["cached_input_tokens"].as_u64().is_some()
                    && usage["input_tokens"].as_u64().is_some();
                let cache_input = (has_cache && (self.has_cache || previous.is_none() || reset))
                    .then_some((delta.input, delta.cached_input));
                self.previous = Some(total);
                self.has_output = has_output;
                self.has_cache = has_cache;
                self.summary.context_used = info["last_token_usage"]["total_tokens"]
                    .as_u64()
                    .unwrap_or(0);
                self.summary.context_limit = info["model_context_window"].as_u64().unwrap_or(0);
                self.summary.events.push(Event {
                    at,
                    project: self.project.clone(),
                    model: self.model.clone(),
                    usage: delta,
                    cycle: self.cycles.get(&self.model).cloned(),
                    cache_input,
                    context_used: self.summary.context_used,
                    context_limit: self.summary.context_limit,
                });
            }
            _ => {}
        }
    }
}
#[cfg(test)]
pub(crate) fn parse(mut reader: impl BufRead) -> Summary {
    let mut parser = Parser::new();
    let mut line = Vec::new();
    while reader.read_until(b'\n', &mut line).unwrap_or(0) > 0 {
        parser.line(&line);
        line.clear();
    }
    parser.displayed()
}
#[derive(Clone, Serialize, Deserialize)]
struct Cached {
    version: u32,
    root: String,
    fingerprint: Fingerprint,
    offset: u64,
    prefix: Vec<u8>,
    tail: Vec<u8>,
    dropping: bool,
    parser: Parser,
    fragment: Option<Parser>,
}
impl Cached {
    fn displayed(&self) -> Summary {
        self.fragment.as_ref().unwrap_or(&self.parser).displayed()
    }
}
#[derive(Default)]
pub struct Reader {
    cache: BTreeMap<PathBuf, Cached>,
    root: Option<PathBuf>,
    cache_directory: Option<PathBuf>,
    local_offset: Option<i32>,
    last: Option<(
        BTreeMap<PathBuf, Fingerprint>,
        DateTime<Utc>,
        DateTime<Utc>,
        Snapshot,
    )>,
    pub stats: ReadStats,
}
impl Reader {
    pub fn with_cache(directory: PathBuf) -> Self {
        Self {
            cache_directory: Some(directory),
            ..Self::default()
        }
    }
    pub fn load(&mut self, root: &Path, now: DateTime<Utc>) -> Result<Snapshot, String> {
        self.load_scoped(root, now, DateTime::<Utc>::MIN_UTC, false)
    }
    fn cache_path(&self, root: &Path, path: &Path) -> Option<PathBuf> {
        self.cache_directory.as_ref().map(|dir| {
            dir.join(crate::context::digest(root.to_string_lossy().as_bytes()))
                .join(format!(
                    "{}.json",
                    crate::context::digest(path.to_string_lossy().as_bytes())
                ))
        })
    }
    pub fn load_scoped(
        &mut self,
        root: &Path,
        now: DateTime<Utc>,
        quota_since: DateTime<Utc>,
        force: bool,
    ) -> Result<Snapshot, String> {
        let root = fs::canonicalize(root).map_err(|_| "无法访问所选目录，请重新选择数据目录")?;
        if self.root.as_ref() != Some(&root) {
            self.cache.clear();
            self.last = None;
            self.root = Some(root.clone());
        }
        self.stats = ReadStats::default();
        let local = now.with_timezone(&Local).fixed_offset();
        let offset = local.offset().local_minus_utc();
        if self.local_offset != Some(offset) {
            self.last = None;
            self.local_offset = Some(offset);
        }
        let mut fingerprints = BTreeMap::new();
        let mut warnings = Vec::new();
        let folders: Vec<PathBuf> =
            if root.join("sessions").is_dir() || root.join("archived_sessions").is_dir() {
                vec![root.join("sessions"), root.join("archived_sessions")]
            } else {
                vec![root.clone()]
            };
        for folder in folders.into_iter().filter(|p| p.is_dir()) {
            for entry in walkdir::WalkDir::new(folder).follow_links(false) {
                let entry = match entry {
                    Ok(e) => e,
                    Err(_) => {
                        warnings.push("部分目录无法读取".to_owned());
                        continue;
                    }
                };
                if entry.file_type().is_file()
                    && entry.path().extension().is_some_and(|e| e == "jsonl")
                {
                    match fingerprint(entry.path()) {
                        Ok(fp) => {
                            fingerprints.insert(entry.path().to_owned(), fp);
                        }
                        Err(_) => warnings.push("部分会话文件无法读取".into()),
                    }
                }
            }
        }
        if !force && warnings.is_empty() {
            if let Some((old, until, since, last)) = &self.last {
                if old == &fingerprints
                    && now < *until
                    && now >= last.observed_at
                    && *since == quota_since
                {
                    let mut snapshot = last.clone();
                    self.stats.reused_files = fingerprints.len();
                    snapshot.observed_at = now;
                    snapshot.read_stats = self.stats.clone();
                    snapshot.prediction = crate::forecast::evaluate(
                        snapshot.seven_day_rate.as_ref(),
                        &snapshot.quota_samples,
                        now,
                    );
                    return Ok(snapshot);
                }
            }
        }
        let mut summaries = Vec::new();
        for (path, fp) in &fingerprints {
            if !force && !self.cache.contains_key(path) {
                if let Some(file) = self.cache_path(&root, path) {
                    if fs::metadata(&file).is_ok_and(|m| m.len() < 64 * 1024 * 1024) {
                        if let Ok(c) = fs::read(file).and_then(|bytes| {
                            serde_json::from_slice::<Cached>(&bytes).map_err(std::io::Error::other)
                        }) {
                            if c.version == 2 && c.root == root.to_string_lossy() {
                                self.cache.insert(path.clone(), c);
                            }
                        }
                    }
                }
            }
            if !force {
                if let Some(c) = self.cache.get(path) {
                    if &c.fingerprint == fp {
                        self.stats.reused_files += 1;
                        summaries.push(c.displayed());
                        continue;
                    }
                }
            }
            self.stats.parsed_files += 1;
            match self.read_file(path, fp, force) {
                Ok(mut cached) => {
                    cached.root = root.to_string_lossy().into_owned();
                    summaries.push(cached.displayed());
                    if fingerprint(path).as_ref().ok() == Some(fp) {
                        if let Some(file) = self.cache_path(&root, path) {
                            match crate::context::write_json(&file, &cached) {
                                Ok(()) => self.stats.persisted_summaries += 1,
                                Err(_) => warnings
                                    .push("统计缓存保存失败，下次启动可能需要重新读取".into()),
                            }
                        }
                        self.cache.insert(path.clone(), cached);
                    } else {
                        self.cache.remove(path);
                        warnings.push("会话文件在读取期间变化，将于下次刷新重试".into());
                    }
                }
                Err(_) => {
                    warnings.push("部分会话文件无法读取".into());
                    if let Some(c) = self.cache.get(path) {
                        summaries.push(c.displayed());
                        self.stats.reused_files += 1;
                    }
                }
            }
        }
        self.cache.retain(|p, _| fingerprints.contains_key(p));
        if !fingerprints.is_empty() && summaries.is_empty() {
            return Err("所有会话文件均读取失败，已保留上次结果".into());
        }
        self.stats.aggregate_builds = 1;
        let snapshot = aggregate(
            &root,
            now,
            quota_since,
            &summaries,
            fingerprints.len(),
            warnings,
            self.stats.clone(),
        );
        let until = local
            .with_minute(0)
            .unwrap()
            .with_second(0)
            .unwrap()
            .with_nanosecond(0)
            .unwrap()
            + Duration::hours(1);
        let mut until = until.with_timezone(&Utc);
        for sample in &snapshot.reply_speed_samples {
            until = until.min(sample.completed_at + Duration::minutes(15));
        }
        for rate in [
            &snapshot.seven_day_rate,
            &snapshot.primary_rate,
            &snapshot.spark_rate,
        ]
        .into_iter()
        .flatten()
        {
            until = until.min(rate.resets_at);
        }
        for s in &summaries {
            for at in s
                .events
                .iter()
                .map(|e| e.at)
                .chain(s.quotas.iter().map(|q| q.at))
                .chain(s.replies.iter().map(|r| r.completed_at))
            {
                if at > now {
                    until = until.min(at);
                }
            }
        }
        if snapshot.warnings.is_empty() {
            self.last = Some((fingerprints, until, quota_since, snapshot.clone()));
        } else {
            self.last = None;
        }
        Ok(snapshot)
    }
    fn read_file(&mut self, path: &Path, fp: &Fingerprint, force: bool) -> std::io::Result<Cached> {
        let mut file = fs::File::open(path)?;
        let mut parser = Parser::new();
        let mut offset = 0;
        let mut dropping = false;
        if !force {
            if let Some(c) = self.cache.get(path) {
                if fp.size > c.fingerprint.size
                    && fp.identity == c.fingerprint.identity
                    && fp.created == c.fingerprint.created
                    && fp.modified >= c.fingerprint.modified
                {
                    let length = c.fingerprint.size.min(4096);
                    let prefix = hash_part(&mut file, 0, length)?;
                    let tail = hash_part(&mut file, c.fingerprint.size - length, length)?;
                    self.stats.bytes_read += length * 2;
                    if prefix == c.prefix && tail == c.tail {
                        parser = c.parser.clone();
                        offset = c.offset;
                        dropping = c.dropping;
                        self.stats.incremental_files += 1;
                    }
                }
            }
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut reader = BufReader::new(file);
        let mut partial = None;
        loop {
            // Bound line memory without ever retaining or caching conversation text.
            let mut line = Vec::new();
            let mut finished = false;
            let mut overflow = dropping;
            let mut read = 0;
            loop {
                let buffer = reader.fill_buf()?;
                if buffer.is_empty() {
                    break;
                }
                let count = buffer
                    .iter()
                    .position(|b| *b == b'\n')
                    .map_or(buffer.len(), |i| {
                        finished = true;
                        i + 1
                    });
                read += count as u64;
                if !overflow && line.len() + count <= 16 * 1024 * 1024 {
                    line.extend_from_slice(&buffer[..count]);
                } else {
                    overflow = true;
                    line.clear();
                }
                reader.consume(count);
                if finished {
                    break;
                }
            }
            self.stats.bytes_read += read;
            if read == 0 {
                break;
            }
            if finished {
                offset += read;
                dropping = false;
                if overflow {
                    parser.summary.malformed += 1;
                } else {
                    parser.line(&line);
                }
            } else if overflow {
                offset += read;
                dropping = true;
                break;
            } else {
                if serde_json::from_slice::<Value>(&line).is_ok() {
                    let mut displayed = parser.clone();
                    displayed.line(&line);
                    partial = Some(displayed);
                }
                break;
            }
        }
        // A valid unterminated last event is visible, but checkpoint before it so
        // an appended newline or remainder can be replayed without double counting.
        let file = reader.into_inner();
        drop(file);
        let mut guard = fs::File::open(path)?;
        let length = fp.size.min(4096);
        let prefix = hash_part(&mut guard, 0, length)?;
        let tail = hash_part(&mut guard, fp.size - length, length)?;
        self.stats.bytes_read += length * 2;
        let cached = Cached {
            version: 2,
            root: String::new(),
            fingerprint: fp.clone(),
            offset,
            prefix,
            tail,
            dropping,
            parser,
            fragment: partial,
        };
        Ok(cached)
    }
}
fn hash_part(file: &mut fs::File, offset: u64, length: u64) -> std::io::Result<Vec<u8>> {
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = vec![0; length as usize];
    file.read_exact(&mut bytes)?;
    Ok(Sha256::digest(bytes).to_vec())
}
fn is_spark(model: &str) -> bool {
    model.to_ascii_lowercase().contains("spark")
}
#[derive(Default)]
struct RankAccumulator {
    tokens: u64,
    sessions: usize,
    turns: usize,
    seconds: f64,
    cache_input: u64,
    cached: u64,
    has_cache: bool,
    last: Option<DateTime<Utc>>,
}
fn rankings(map: BTreeMap<String, RankAccumulator>) -> Vec<Ranked> {
    let mut rows: Vec<_> = map
        .into_iter()
        .map(|(name, a)| Ranked {
            name,
            tokens: a.tokens,
            sessions: a.sessions,
            requests: a.turns,
            average_turn_seconds: (a.turns > 0).then_some(a.seconds / a.turns.max(1) as f64),
            cache_hit_rate: (a.has_cache && a.cache_input > 0)
                .then_some(a.cached as f64 / a.cache_input.max(1) as f64),
            last_active: a.last,
        })
        .collect();
    rows.sort_by(|a, b| b.tokens.cmp(&a.tokens).then(a.name.cmp(&b.name)));
    rows
}
fn aggregate(
    root: &Path,
    now: DateTime<Utc>,
    since: DateTime<Utc>,
    summaries: &[Summary],
    files: usize,
    mut warnings: Vec<String>,
    stats: ReadStats,
) -> Snapshot {
    let today = now.with_timezone(&Local).date_naive();
    let start = today - Duration::days(6);
    let thirty = today - Duration::days(29);
    let mut snap = Snapshot {
        all_time: Tokens::default(),
        today: Tokens::default(),
        last_seven_days: Tokens::default(),
        this_month: Tokens::default(),
        daily_usage: (0..7)
            .map(|i| Day {
                date: (start + Duration::days(i)).to_string(),
                tokens: 0,
            })
            .collect(),
        hourly_usage: vec![],
        projects: vec![],
        today_projects: vec![],
        month_projects: vec![],
        models: vec![],
        records: vec![],
        seven_day_rate: None,
        primary_rate: None,
        spark_rate: None,
        reply_speed_samples: vec![],
        rate_timeline: vec![],
        quota_samples: vec![],
        prediction: crate::forecast::Prediction::default(),
        current_context_used: 0,
        context_window: 0,
        last_updated: None,
        observed_at: now,
        main_rate_sampled_at: None,
        primary_rate_sampled_at: None,
        spark_rate_sampled_at: None,
        file_count: files,
        session_count: 0,
        data_path: root.to_string_lossy().into_owned(),
        warnings: vec![],
        read_stats: stats,
        account_status: String::new(),
        quota_waiting_message: String::new(),
        context_id: String::new(),
    };
    let mut projects = BTreeMap::<String, RankAccumulator>::new();
    let mut today_projects = BTreeMap::<String, RankAccumulator>::new();
    let mut month_projects = BTreeMap::<String, RankAccumulator>::new();
    let mut models = BTreeMap::<String, RankAccumulator>::new();
    let mut records = BTreeMap::<(DateTime<Utc>, String, String), u64>::new();
    let mut hours = BTreeMap::<DateTime<Utc>, u64>::new();
    let mut cycle_tokens = BTreeMap::<(String, DateTime<Utc>), u64>::new();
    let mut timeline = BTreeMap::<(String, DateTime<Utc>), RateCycle>::new();
    let mut chosen: Option<Quota> = None;
    let mut primary: Option<Quota> = None;
    let mut spark: Option<Quota> = None;
    for summary in summaries {
        if summary.malformed > 0 {
            warnings.push("部分记录格式异常，统计可能不完整".into());
        }
        let mut week_seen = BTreeSet::new();
        let mut today_seen = BTreeSet::new();
        let mut month_seen = BTreeSet::new();
        if summary.events.iter().any(|e| e.at <= now) {
            snap.session_count += 1;
        }
        for e in summary.events.iter().filter(|e| e.at <= now) {
            let day = e.at.with_timezone(&Local).date_naive();
            snap.all_time.add(&e.usage);
            if snap.last_updated.is_none_or(|last| e.at >= last) {
                snap.last_updated = Some(e.at);
                snap.current_context_used = e.context_used;
                snap.context_window = e.context_limit;
            }
            if day.year() == today.year() && day.month() == today.month() {
                snap.this_month.add(&e.usage);
            }
            let hour =
                e.at.with_minute(0)
                    .unwrap()
                    .with_second(0)
                    .unwrap()
                    .with_nanosecond(0)
                    .unwrap();
            if day >= thirty && e.usage.total > 0 {
                *records
                    .entry((hour, e.project.clone(), e.model.clone()))
                    .or_default() += e.usage.total;
                let a = month_projects.entry(e.project.clone()).or_default();
                a.tokens += e.usage.total;
                a.last = Some(a.last.map_or(e.at, |old| old.max(e.at)));
                month_seen.insert(e.project.clone());
            }
            if e.at > now - Duration::hours(24) {
                *hours.entry(hour).or_default() += e.usage.total;
            }
            if day == today {
                snap.today.add(&e.usage);
                let a = today_projects.entry(e.project.clone()).or_default();
                a.tokens += e.usage.total;
                a.last = Some(a.last.map_or(e.at, |old| old.max(e.at)));
                today_seen.insert(e.project.clone());
            }
            if day >= start {
                snap.last_seven_days.add(&e.usage);
                snap.daily_usage[(day - start).num_days() as usize].tokens += e.usage.total;
                let a = projects.entry(e.project.clone()).or_default();
                a.tokens += e.usage.total;
                a.last = Some(a.last.map_or(e.at, |old| old.max(e.at)));
                week_seen.insert(e.project.clone());
                if !is_spark(&e.model) {
                    let a = models.entry(e.model.clone()).or_default();
                    a.tokens += e.usage.total;
                    if let Some((input, cached)) = e.cache_input {
                        a.has_cache = true;
                        a.cache_input += input;
                        a.cached += cached;
                    }
                }
            }
            if e.at >= since && !is_spark(&e.model) {
                if let Some((id, end)) = &e.cycle {
                    if e.at < *end {
                        *cycle_tokens.entry((id.clone(), *end)).or_default() += e.usage.total;
                    }
                }
            }
        }
        for name in week_seen {
            projects.entry(name).or_default().sessions += 1;
        }
        for name in today_seen {
            today_projects.entry(name).or_default().sessions += 1;
        }
        for name in month_seen {
            month_projects.entry(name).or_default().sessions += 1;
        }
        for turn in &summary.turns {
            if turn.at <= now
                && turn.at.with_timezone(&Local).date_naive() >= start
                && !is_spark(&turn.model)
            {
                let a = models.entry(turn.model.clone()).or_default();
                a.turns += 1;
                a.seconds += turn.seconds;
            }
        }
        snap.reply_speed_samples.extend(
            summary
                .replies
                .iter()
                .filter(|r| r.completed_at <= now && r.completed_at > now - Duration::minutes(15))
                .cloned(),
        );
        for q in summary
            .quotas
            .iter()
            .filter(|q| q.at >= since && q.at <= now)
        {
            if is_spark(&q.model) {
                if q.rate.window_minutes == 10080 && spark.as_ref().is_none_or(|old| q.at > old.at)
                {
                    spark = Some(q.clone());
                }
                continue;
            }
            let target = if q.rate.window_minutes == 10080 {
                &mut chosen
            } else {
                &mut primary
            };
            if target.as_ref().is_none_or(|old| {
                q.canonical && !old.canonical || q.canonical == old.canonical && q.at > old.at
            }) {
                *target = Some(q.clone());
            }
            if q.rate.window_minutes == 10080 && q.at.with_timezone(&Local).date_naive() >= thirty {
                let key = (q.id.clone(), q.rate.resets_at);
                if timeline.get(&key).is_none_or(|old| q.at > old.date) {
                    timeline.insert(
                        key,
                        RateCycle {
                            date: q.at,
                            used_percent: q.rate.used_percent,
                            resets_at: q.rate.resets_at,
                            limit_id: q.id.clone(),
                            tokens: 0,
                        },
                    );
                }
            }
        }
    }
    let selected = chosen.as_ref().map(|q| q.id.clone());
    snap.quota_samples = summaries
        .iter()
        .flat_map(|s| s.quotas.iter())
        .filter(|q| {
            q.at >= since
                && q.at <= now
                && q.at > now - Duration::days(30)
                && q.rate.window_minutes == 10080
                && !is_spark(&q.model)
                && selected.as_ref().is_some_and(|id| id == &q.id)
        })
        .map(|q| RateCycle {
            date: q.at,
            used_percent: q.rate.used_percent,
            resets_at: q.rate.resets_at,
            limit_id: q.id.clone(),
            tokens: 0,
        })
        .collect();
    snap.quota_samples.sort_by_key(|q| q.date);
    snap.quota_samples
        .dedup_by(|a, b| a.date == b.date && a.resets_at == b.resets_at);
    snap.main_rate_sampled_at = chosen
        .as_ref()
        .filter(|q| q.rate.resets_at > now)
        .map(|q| q.at);
    snap.primary_rate_sampled_at = primary
        .as_ref()
        .filter(|q| q.rate.resets_at > now)
        .map(|q| q.at);
    snap.spark_rate_sampled_at = spark
        .as_ref()
        .filter(|q| q.rate.resets_at > now)
        .map(|q| q.at);
    snap.seven_day_rate = chosen.filter(|q| q.rate.resets_at > now).map(|q| q.rate);
    snap.primary_rate = primary.filter(|q| q.rate.resets_at > now).map(|q| q.rate);
    snap.spark_rate = spark.filter(|q| q.rate.resets_at > now).map(|q| q.rate);
    snap.rate_timeline = timeline
        .into_iter()
        .filter(|((id, _), _)| selected.as_ref().is_none_or(|selected| id == selected))
        .map(|(key, mut value)| {
            value.tokens = cycle_tokens.get(&key).copied().unwrap_or(0);
            value
        })
        .collect();
    snap.rate_timeline.sort_by(|a, b| b.date.cmp(&a.date));
    snap.projects = rankings(projects);
    snap.today_projects = rankings(today_projects);
    snap.month_projects = rankings(month_projects);
    snap.models = rankings(models);
    snap.records = records
        .into_iter()
        .rev()
        .map(|((date, project, model), tokens)| Record {
            date,
            project,
            model,
            tokens,
        })
        .collect();
    snap.hourly_usage = hours
        .into_iter()
        .map(|(date, tokens)| Day {
            date: date.to_rfc3339(),
            tokens,
        })
        .collect();
    warnings.sort();
    warnings.dedup();
    snap.warnings = warnings;
    snap.prediction =
        crate::forecast::evaluate(snap.seven_day_rate.as_ref(), &snap.quota_samples, now);
    snap
}
