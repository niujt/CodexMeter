use chrono::{DateTime, Duration, Timelike, Utc};
use codex_health_usage::{Reader, Snapshot};
use serde_json::{json, Value};
use std::{fs, io::Write, path::PathBuf};
fn now() -> DateTime<Utc> {
    Utc::now()
        .with_minute(20)
        .unwrap()
        .with_second(0)
        .unwrap()
        .with_nanosecond(0)
        .unwrap()
}
fn fixture(name: &str) -> (PathBuf, PathBuf) {
    let base = std::env::var_os("CODEX_HEALTH_TEST_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join(format!(
            "windows-{name}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
    let root = base.join(".codex");
    fs::create_dir_all(root.join("sessions")).unwrap();
    (root, base.join("cache"))
}
fn token(
    at: DateTime<Utc>,
    input: u64,
    output: u64,
    cache: u64,
    quota: Option<(f64, i64)>,
) -> Value {
    let mut p = json!({"type":"token_count","info":{"total_token_usage":{"input_tokens":input,"cached_input_tokens":cache,"output_tokens":output,"total_tokens":input+output},"last_token_usage":{"total_tokens":30},"model_context_window":200000}});
    if let Some((percent, end)) = quota {
        p["rate_limits"] = json!({"limit_id":"codex","secondary":{"used_percent":percent,"window_minutes":10080,"resets_at":end}});
    }
    json!({"type":"event_msg","timestamp":at.to_rfc3339(),"payload":p})
}
fn message(at: DateTime<Utc>, role: &str, phase: Option<&str>) -> Value {
    json!({"type":"response_item","timestamp":at.to_rfc3339(),"payload":{"type":"message","role":role,"phase":phase,"content":"PRIVATE_SYNTHETIC_CONTENT"}})
}
fn event(at: DateTime<Utc>, ty: &str) -> Value {
    json!({"type":"event_msg","timestamp":at.to_rfc3339(),"payload":{"type":ty}})
}
fn write(root: &std::path::Path, values: Vec<Value>, newline: bool) {
    let mut text = values
        .into_iter()
        .map(|v| v.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    if newline {
        text.push('\n')
    };
    fs::write(root.join("sessions/test.jsonl"), text).unwrap();
}
fn append(root: &std::path::Path, value: Value) {
    let mut f = fs::OpenOptions::new()
        .append(true)
        .open(root.join("sessions/test.jsonl"))
        .unwrap();
    writeln!(f, "{value}").unwrap();
}
fn content(snapshot: &Snapshot) -> Value {
    let mut value = serde_json::to_value(snapshot).unwrap();
    value.as_object_mut().unwrap().remove("readStats");
    value
}
#[test]
fn quota_only_update_changes_97_to_91_without_changing_token_counters() {
    let at = now();
    let (root, cache) = fixture("quota-only");
    let reset = (at + Duration::days(7)).timestamp();
    write(&root, vec![token(at, 80, 20, 0, Some((3., reset)))], true);
    let mut reader = Reader::with_cache(cache.clone());
    let first = reader.load(&root, at).unwrap();
    assert_eq!(first.seven_day_rate.unwrap().used_percent, 3.);
    let sampled = at + Duration::seconds(10);
    append(
        &root,
        json!({"type":"event_msg","timestamp":sampled.to_rfc3339(),"payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":12,"window_minutes":300,"resets_at":reset},"secondary":{"used_percent":9,"window_minutes":10080,"resets_at":reset}}}}),
    );
    let quota_only = reader.load(&root, sampled).unwrap();
    assert_eq!(quota_only.seven_day_rate.as_ref().unwrap().used_percent, 9.);
    assert_eq!(quota_only.main_rate_sampled_at, Some(sampled));
    assert_eq!(quota_only.primary_rate_sampled_at, Some(sampled));
    assert_eq!(quota_only.all_time.total, 100);
    assert_eq!(quota_only.context_window, first.context_window);
    assert!(quota_only.warnings.is_empty());
    append(
        &root,
        token(sampled + Duration::seconds(1), 100, 30, 0, None),
    );
    let checked = sampled + Duration::seconds(60);
    let last = reader.load(&root, checked).unwrap();
    assert_eq!(last.all_time.total, 130);
    assert_eq!(last.main_rate_sampled_at, Some(sampled));
    let restarted = Reader::with_cache(cache).load(&root, checked).unwrap();
    assert_eq!(content(&restarted), content(&last));
    assert_eq!(restarted.read_stats.parsed_files, 0);
}

#[test]
fn quota_only_file_and_invalid_token_payload_still_update_quota() {
    let at = now();
    let (root, _) = fixture("quota-no-tokens");
    let reset = (at + Duration::days(7)).timestamp();
    let quota = |info: Value, percent: f64| json!({"type":"event_msg","timestamp":at.to_rfc3339(),"payload":{"type":"token_count","info":info,"rate_limits":{"limit_id":"codex","secondary":{"used_percent":percent,"window_minutes":10080,"resets_at":reset}}}});
    write(&root, vec![quota(Value::Null, 9.)], true);
    let snapshot = Reader::default().load(&root, at).unwrap();
    assert_eq!(snapshot.seven_day_rate.unwrap().used_percent, 9.);
    assert_eq!(snapshot.all_time.total, 0);
    assert!(snapshot.warnings.is_empty());
    write(
        &root,
        vec![quota(
            json!({"total_token_usage":{"total_tokens":"invalid"}}),
            12.,
        )],
        true,
    );
    let snapshot = Reader::default().load(&root, at).unwrap();
    assert_eq!(snapshot.seven_day_rate.unwrap().used_percent, 12.);
    assert_eq!(snapshot.all_time.total, 0);
    assert!(!snapshot.warnings.is_empty());
}

#[test]
fn old_parser_cache_is_rebuilt_without_deleting_source_or_cache_files() {
    let at = now();
    let (root, cache) = fixture("quota-cache-version");
    write(
        &root,
        vec![token(
            at,
            80,
            20,
            0,
            Some((9., (at + Duration::days(7)).timestamp())),
        )],
        true,
    );
    Reader::with_cache(cache.clone()).load(&root, at).unwrap();
    let mut migrated = 0;
    for entry in walkdir::WalkDir::new(&cache)
        .into_iter()
        .flatten()
        .filter(|e| e.file_type().is_file())
    {
        migrated += 1;
        let mut cached: Value = serde_json::from_slice(&fs::read(entry.path()).unwrap()).unwrap();
        cached["version"] = json!(1);
        cached["parser"]["summary"]["quotas"] = json!([]);
        fs::write(entry.path(), serde_json::to_vec(&cached).unwrap()).unwrap();
    }
    assert_eq!(migrated, 1);
    let snapshot = Reader::with_cache(cache).load(&root, at).unwrap();
    assert_eq!(snapshot.seven_day_rate.unwrap().used_percent, 9.);
    assert_eq!(snapshot.read_stats.parsed_files, 1);
}
#[test]
fn turns_speed_cache_hit_and_context_match_native_semantics() {
    let at = now();
    let (root, _) = fixture("metrics");
    write(
        &root,
        vec![
            json!({"type":"turn_context","payload":{"model":"gpt-test"}}),
            token(at - Duration::seconds(120), 100, 100, 40, None),
            event(at - Duration::seconds(60), "task_started"),
            message(at - Duration::seconds(58), "user", None),
            token(at - Duration::seconds(30), 200, 300, 100, None),
            message(
                at - Duration::seconds(20),
                "assistant",
                Some("final_answer"),
            ),
            token(at - Duration::seconds(19), 250, 350, 125, None),
            event(at - Duration::seconds(18), "task_complete"),
        ],
        true,
    );
    let s = Reader::default().load(&root, at).unwrap();
    assert_eq!(s.reply_speed_samples.len(), 1);
    assert_eq!(s.reply_speed_samples[0].output_tokens, 250);
    assert_eq!(s.reply_speed_samples[0].turn_seconds, 40.);
    assert_eq!(s.models[0].requests, 1);
    assert_eq!(s.models[0].average_turn_seconds, Some(38.));
    assert_eq!(s.models[0].cache_hit_rate, Some(0.5));
    assert_eq!(s.current_context_used, 30);
    assert_eq!(s.context_window, 200000);
}
#[test]
fn cumulative_without_baseline_never_becomes_reply_speed() {
    let at = now();
    let (root, _) = fixture("baseline");
    write(
        &root,
        vec![
            message(at - Duration::seconds(30), "user", None),
            token(at - Duration::seconds(10), 100, 1000, 0, None),
            message(at - Duration::seconds(5), "assistant", Some("final_answer")),
        ],
        true,
    );
    let s = Reader::default().load(&root, at).unwrap();
    assert!(s.reply_speed_samples.is_empty());
    assert_eq!(s.models[0].requests, 1);
}
#[test]
fn cached_eof_reply_is_retracted_by_abort_and_restart_append_is_exact() {
    let at = now();
    let (root, cache) = fixture("eof");
    write(
        &root,
        vec![
            token(at - Duration::seconds(100), 100, 100, 0, None),
            message(at - Duration::seconds(50), "user", None),
            token(at - Duration::seconds(30), 150, 250, 0, None),
            message(
                at - Duration::seconds(20),
                "assistant",
                Some("final_answer"),
            ),
        ],
        true,
    );
    let first = Reader::with_cache(cache.clone()).load(&root, at).unwrap();
    assert_eq!(first.reply_speed_samples.len(), 1);
    append(&root, event(at - Duration::seconds(10), "task_aborted"));
    let mut restarted = Reader::with_cache(cache);
    let s = restarted.load(&root, at).unwrap();
    assert_eq!(s.read_stats.incremental_files, 1);
    assert!(s.reply_speed_samples.is_empty());
    assert_eq!(
        content(&s),
        content(&Reader::default().load(&root, at).unwrap())
    );
}
#[test]
fn unterminated_and_partial_lines_resume_without_double_counting() {
    let at = now();
    let (root, cache) = fixture("partial");
    write(
        &root,
        vec![
            token(at - Duration::seconds(100), 100, 10, 0, None),
            token(at - Duration::seconds(50), 200, 20, 0, None),
        ],
        false,
    );
    let first = Reader::with_cache(cache.clone()).load(&root, at).unwrap();
    assert_eq!(first.all_time.total, 220);
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(root.join("sessions/test.jsonl"))
        .unwrap();
    writeln!(file).unwrap();
    writeln!(
        file,
        "{}",
        token(at - Duration::seconds(10), 300, 30, 0, None)
    )
    .unwrap();
    drop(file);
    let s = Reader::with_cache(cache.clone()).load(&root, at).unwrap();
    assert_eq!(s.all_time.total, 330);
    assert_eq!(s.read_stats.incremental_files, 1);
    let next = token(at - Duration::seconds(5), 400, 40, 0, None).to_string();
    let half = next.len() / 2;
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(root.join("sessions/test.jsonl"))
        .unwrap();
    write!(file, "{}", &next[..half]).unwrap();
    drop(file);
    assert_eq!(
        Reader::with_cache(cache.clone())
            .load(&root, at)
            .unwrap()
            .all_time
            .total,
        330
    );
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(root.join("sessions/test.jsonl"))
        .unwrap();
    writeln!(file, "{}", &next[half..]).unwrap();
    drop(file);
    let s = Reader::with_cache(cache).load(&root, at).unwrap();
    assert_eq!(s.all_time.total, 440);
}
#[test]
fn unchanged_refresh_and_restart_do_no_source_reads_or_cache_writes() {
    let at = now();
    let (root, cache) = fixture("idle");
    write(
        &root,
        vec![token(at - Duration::seconds(1), 100, 100, 50, None)],
        true,
    );
    let mut reader = Reader::with_cache(cache.clone());
    reader.load(&root, at).unwrap();
    let s = reader.load(&root, at + Duration::seconds(1)).unwrap();
    assert_eq!(s.read_stats.bytes_read, 0);
    assert_eq!(s.read_stats.aggregate_builds, 0);
    assert_eq!(s.read_stats.persisted_summaries, 0);
    let restarted = Reader::with_cache(cache)
        .load(&root, at + Duration::seconds(1))
        .unwrap();
    assert_eq!(restarted.read_stats.bytes_read, 0);
    assert_eq!(restarted.read_stats.parsed_files, 0);
}
#[test]
fn login_boundary_and_multiple_same_day_resets_preserve_tokens() {
    let at = now();
    let (root, _) = fixture("cycles");
    let end1 = (at - Duration::minutes(1)).timestamp();
    let end2 = (at + Duration::days(7)).timestamp();
    write(
        &root,
        vec![
            token(at - Duration::minutes(10), 100, 0, 0, Some((10., end1))),
            token(at - Duration::minutes(2), 150, 0, 0, Some((20., end1))),
            token(at - Duration::seconds(30), 175, 0, 0, Some((5., end2))),
        ],
        true,
    );
    let mut reader = Reader::default();
    let s = reader.load(&root, at).unwrap();
    assert_eq!(s.rate_timeline.len(), 2);
    assert_eq!(s.rate_timeline[0].tokens, 25);
    assert_eq!(s.rate_timeline[1].tokens, 150);
    let bounded = reader.load_scoped(&root, at, at, false).unwrap();
    assert!(bounded.seven_day_rate.is_none());
    assert_eq!(bounded.all_time.total, 175);
    assert!(bounded.rate_timeline.is_empty());
}
#[test]
fn append_cost_is_bounded_and_cache_never_contains_message_text() {
    let at = now();
    let (root, cache) = fixture("long");
    let mut values = vec![message(at - Duration::seconds(100), "user", None)];
    for i in 0..2000 {
        values.push(token(at - Duration::seconds(50), i * 10, i, 0, None));
    }
    write(&root, values, true);
    let mut reader = Reader::with_cache(cache.clone());
    let cold = reader.load(&root, at).unwrap().read_stats.bytes_read;
    append(
        &root,
        token(at - Duration::seconds(1), 20010, 2001, 0, None),
    );
    let s = reader.load(&root, at).unwrap();
    assert_eq!(s.read_stats.incremental_files, 1);
    assert!(s.read_stats.bytes_read < 20000 && s.read_stats.bytes_read < cold / 10);
    for dir in fs::read_dir(cache).unwrap().flatten() {
        for file in fs::read_dir(dir.path()).unwrap().flatten() {
            let text = fs::read_to_string(file.path()).unwrap();
            assert!(!text.contains("PRIVATE_SYNTHETIC_CONTENT"));
        }
    }
}
#[test]
fn speed_expiry_rebuilds_aggregate_without_reading_source() {
    let at = now();
    let (root, _) = fixture("expiry");
    write(
        &root,
        vec![
            token(at - Duration::minutes(15), 0, 100, 0, None),
            message(at - Duration::minutes(14), "user", None),
            token(at - Duration::minutes(13), 100, 300, 0, None),
            message(
                at - Duration::minutes(13),
                "assistant",
                Some("final_answer"),
            ),
        ],
        true,
    );
    let mut reader = Reader::default();
    assert_eq!(reader.load(&root, at).unwrap().reply_speed_samples.len(), 1);
    let s = reader.load(&root, at + Duration::minutes(3)).unwrap();
    assert!(s.reply_speed_samples.is_empty());
    assert_eq!(s.read_stats.bytes_read, 0);
}
