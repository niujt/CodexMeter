export interface Tokens {
  input: number;
  cachedInput: number;
  output: number;
  reasoningOutput: number;
  total: number;
}
export interface Rate {
  usedPercent: number;
  windowMinutes: number;
  resetsAt: string;
}
export interface Ranked {
  name: string;
  tokens: number;
  sessions: number;
  requests: number;
  averageTurnSeconds: number | null;
  cacheHitRate: number | null;
  lastActive: string | null;
}
export interface UsageRecord {
  date: string;
  project: string;
  model: string;
  tokens: number;
}
export interface ReplySample {
  completedAt: string;
  outputTokens: number;
  turnSeconds: number;
}
export interface RateCycle {
  date: string;
  usedPercent: number;
  resetsAt: string;
  limitId: string;
  tokens: number;
}
export interface Prediction {
  percentPerHour: number | null;
  windowsUsed: number[];
  remainingHours: number | null;
  willExhaust: boolean;
  health: string;
}
export interface Snapshot {
  allTime: Tokens;
  today: Tokens;
  lastSevenDays: Tokens;
  thisMonth: Tokens;
  dailyUsage: { date: string; tokens: number }[];
  hourlyUsage: { date: string; tokens: number }[];
  projects: Ranked[];
  todayProjects: Ranked[];
  monthProjects: Ranked[];
  models: Ranked[];
  records: UsageRecord[];
  sevenDayRate: Rate | null;
  primaryRate: Rate | null;
  sparkRate: Rate | null;
  replySpeedSamples: ReplySample[];
  rateTimeline: RateCycle[];
  quotaSamples: RateCycle[];
  prediction: Prediction;
  currentContextUsed: number;
  contextWindow: number;
  lastUpdated: string | null;
  observedAt: string;
  mainRateSampledAt: string | null;
  primaryRateSampledAt?: string | null;
  sparkRateSampledAt?: string | null;
  fileCount: number;
  sessionCount: number;
  dataPath: string;
  warnings: string[];
  accountStatus: string;
  quotaWaitingMessage: string;
  contextId: string;
  readStats: {
    parsedFiles: number;
    reusedFiles: number;
    incrementalFiles: number;
    bytesRead: number;
    persistedSummaries: number;
    aggregateBuilds: number;
  };
}
export interface Preferences {
  directory: string | null;
  appearance: "system" | "light" | "dark";
  iconStyle: "flat" | "glass";
  refreshInterval: number;
  lowRateThreshold: number;
  deduplicateAlerts: boolean;
  quotaNotifications: boolean;
  permissionEnabled: boolean;
  systemNotifications: boolean;
  badgeEnabled: boolean;
  soundEnabled: boolean;
  showPreview: boolean;
  retentionHours: number;
  followedPaths: string[];
  floatingEnabled: boolean;
  floatingStyle: "ball" | "summary";
}
export interface PermissionEvent {
  eventId: string;
  receivedAt: string;
  sessionId: string;
  turnId: string;
  project: string;
  toolName: string;
  mode: string;
  model: string;
  attention: "human" | "possible" | "info";
  status: "new" | "seen" | "dismissed" | "expired";
}
export interface ResetEvent {
  id: string;
  kind: string;
  occurred_at: string;
}
export interface Bootstrap {
  preferencesSaved: boolean;
  preferences: Preferences;
  snapshot: Snapshot | null;
  permissions: PermissionEvent[];
  hookStatus: string;
  lowPower: boolean;
  mainVisible: boolean;
  floatingVisible: boolean;
}
export const defaultPreferences: Preferences = {
  directory: null,
  appearance: "system",
  iconStyle: "flat",
  refreshInterval: 300,
  lowRateThreshold: 20,
  deduplicateAlerts: true,
  quotaNotifications: true,
  permissionEnabled: false,
  systemNotifications: true,
  badgeEnabled: true,
  soundEnabled: true,
  showPreview: false,
  retentionHours: 24,
  followedPaths: [],
  floatingEnabled: true,
  floatingStyle: "ball",
};
export const tokens = (n: number) =>
  n >= 1_000_000
    ? `${(n / 1_000_000).toLocaleString("en-US", { maximumFractionDigits: 1 })}M`
    : n >= 1_000
      ? `${(n / 1_000).toLocaleString("en-US", { maximumFractionDigits: 1 })}K`
      : n.toLocaleString("en-US");
export const exact = (n: number) => n.toLocaleString("en-US");
export function projectName(path: string) {
  return path.split(/[\\/]/).filter(Boolean).pop() || path;
}
export function remainingQuota(
  rate: Rate | null,
  now = Date.now(),
): number | null {
  if (
    !rate ||
    !Number.isFinite(rate.usedPercent) ||
    !Number.isFinite(Date.parse(rate.resetsAt)) ||
    Date.parse(rate.resetsAt) <= now
  )
    return null;
  return Math.round(Math.min(100, Math.max(0, 100 - rate.usedPercent)));
}
export const quotaSampleLifetime = 15 * 60_000;
export function quotaDisplay(rate: Rate | null, sampledAt: string | null | undefined, now = Date.now()) {
  const lastRemaining = remainingQuota(rate, now);
  const sampled = sampledAt ? Date.parse(sampledAt) : NaN;
  const validTime = Number.isFinite(sampled) && sampled <= now;
  const stale = validTime && now - sampled >= quotaSampleLifetime;
  const remaining = lastRemaining !== null && validTime && !stale ? lastRemaining : null;
  // A valid observation stays visible until reset, even when it cannot support a current prediction.
  const recordedRemaining = validTime ? lastRemaining : null;
  const time = validTime ? `采样于 ${new Date(sampled).toLocaleString()}` : '采样时间未知';
  return {
    remaining,
    recordedRemaining,
    lastRemaining,
    stale,
    label: `${stale ? '旧采样' : '本地采样'} · ${time} · 非实时`,
  };
}
export function replySpeed(samples: ReplySample[], now = Date.now()) {
  const valid = samples.filter(
    (s) =>
      Date.parse(s.completedAt) > now - 900_000 &&
      Date.parse(s.completedAt) <= now &&
      s.outputTokens > 0 &&
      Number.isFinite(s.turnSeconds) &&
      s.turnSeconds > 0 &&
      s.turnSeconds <= 3600,
  );
  if (!valid.length) return null;
  return {
    sampleCount: valid.length,
    tokensPerSecond:
      valid.reduce((sum, s) => sum + s.outputTokens, 0) /
      valid.reduce((sum, s) => sum + s.turnSeconds, 0),
  };
}
export function duration(seconds: number | null | undefined) {
  if (seconds == null || !Number.isFinite(seconds)) return "样本不足";
  return seconds < 60
    ? `${Math.round(seconds)}秒`
    : seconds < 3600
      ? `${Math.floor(seconds / 60)}分${Math.round(seconds % 60)}秒`
      : `${Math.floor(seconds / 3600)}小时${Math.round((seconds % 3600) / 60)}分`;
}
export function hours(value: number | null) {
  return value == null
    ? "样本不足"
    : value < 1
      ? `${Math.round(value * 60)}分钟`
      : `${value.toLocaleString("zh-CN", { maximumFractionDigits: 1 })}小时`;
}
export function nextDisplayDeadline(
  snapshot: Snapshot | null,
  now: number,
): number | null {
  if (!snapshot) return null;
  const deadlines = [
    snapshot.sevenDayRate,
    snapshot.primaryRate,
    snapshot.sparkRate,
  ].flatMap((r) => (r ? [Date.parse(r.resetsAt)] : []));
  for (const at of [snapshot.mainRateSampledAt, snapshot.primaryRateSampledAt, snapshot.sparkRateSampledAt])
    if (at) deadlines.push(Date.parse(at) + quotaSampleLifetime);
  for (const sample of snapshot.replySpeedSamples)
    deadlines.push(
      Math.ceil((Date.parse(sample.completedAt) + 900_000) / 60_000) * 60_000,
    );
  const valid = deadlines.filter((d) => Number.isFinite(d) && d > now);
  return valid.length ? Math.min(...valid) : null;
}
