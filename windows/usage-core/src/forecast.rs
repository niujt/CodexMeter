use crate::{Rate, RateCycle};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Prediction {
    pub percent_per_hour: Option<f64>,
    pub windows_used: Vec<u32>,
    pub remaining_hours: Option<f64>,
    pub will_exhaust: bool,
    pub health: String,
}
impl Default for Prediction {
    fn default() -> Self {
        Self {
            percent_per_hour: None,
            windows_used: vec![],
            remaining_hours: None,
            will_exhaust: false,
            health: "等待新周期数据".into(),
        }
    }
}
pub fn evaluate(rate: Option<&Rate>, samples: &[RateCycle], now: DateTime<Utc>) -> Prediction {
    let Some(rate) = rate.filter(|r| r.resets_at > now) else {
        return Prediction::default();
    };
    let remaining = (100. - rate.used_percent).clamp(0., 100.);
    let hours = (rate.resets_at - now).num_milliseconds() as f64 / 3_600_000.;
    let mut weighted = 0.;
    let mut weights = 0.;
    let mut windows = vec![];
    for (window, weight) in [(1, 0.5), (6, 0.3), (24, 0.2)] {
        let cutoff = now - Duration::hours(window);
        let valid: Vec<_> = samples
            .iter()
            .filter(|s| s.resets_at == rate.resets_at && s.date >= cutoff && s.date <= now)
            .collect();
        if let (Some(first), Some(last)) = (valid.first(), valid.last()) {
            let elapsed = (last.date - first.date).num_milliseconds() as f64 / 3_600_000.;
            let delta = last.used_percent - first.used_percent;
            if elapsed >= 1. / 12. && delta > 0. {
                weighted += delta / elapsed * weight;
                weights += weight;
                windows.push(window as u32);
            }
        }
    }
    let elapsed = rate.window_minutes as f64 / 60. - hours;
    let speed = if weights > 0. {
        Some(weighted / weights)
    } else if elapsed > 0. && rate.used_percent > 0. {
        Some(rate.used_percent / elapsed.max(0.1))
    } else {
        None
    };
    let remaining_hours = speed
        .filter(|s| s.is_finite() && *s > 0.)
        .map(|s| remaining / s);
    let will_exhaust = remaining_hours.is_some_and(|h| h < hours);
    let health = if remaining < 20. {
        "额度紧张"
    } else if speed.is_none() {
        "样本不足"
    } else if remaining < 50. || will_exhaust {
        "需要关注"
    } else {
        "状态良好"
    };
    Prediction {
        percent_per_hour: speed,
        windows_used: windows,
        remaining_hours,
        will_exhaust,
        health: health.into(),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn expired_rate_and_future_samples_are_ignored() {
        let now = Utc::now();
        let rate = Rate {
            used_percent: 42.,
            window_minutes: 10080,
            resets_at: now,
        };
        assert_eq!(evaluate(Some(&rate), &[], now).health, "等待新周期数据");
    }
    #[test]
    fn weighted_uses_actual_delta_and_same_cycle() {
        let now = Utc::now();
        let end = now + Duration::days(6);
        let rate = Rate {
            used_percent: 20.,
            window_minutes: 10080,
            resets_at: end,
        };
        let samples = vec![
            RateCycle {
                date: now - Duration::minutes(30),
                used_percent: 15.,
                resets_at: end,
                limit_id: "codex".into(),
                tokens: 0,
            },
            RateCycle {
                date: now,
                used_percent: 20.,
                resets_at: end,
                limit_id: "codex".into(),
                tokens: 0,
            },
        ];
        let p = evaluate(Some(&rate), &samples, now);
        assert!((p.percent_per_hour.unwrap() - 10.).abs() < 0.001);
        assert!(p.will_exhaust);
    }
}
