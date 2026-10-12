import { describe, it, expect } from "vitest";
import { replySpeed, nextDisplayDeadline, type Snapshot } from "./types";
describe("可见界面只按数据到期计时", () => {
  it("空数据没有持续定时器", () => {
    expect(nextDisplayDeadline(null, 0)).toBeNull();
  });
  it("按最近到期数据设置一次性 deadline", () => {
    const now = Date.parse("2026-10-13T00:00:00Z");
    const s = {
      sevenDayRate: {
        usedPercent: 42,
        windowMinutes: 10080,
        resetsAt: "2026-10-13T01:00:00Z",
      },
      primaryRate: null,
      sparkRate: null,
      replySpeedSamples: [
        {
          completedAt: "2026-10-12T23:50:00Z",
          outputTokens: 200,
          turnSeconds: 20,
        },
      ],
    } as Snapshot;
    expect(nextDisplayDeadline(s, now)).toBe(now + 300000);
    expect(nextDisplayDeadline({ ...s, replySpeedSamples: [] }, now)).toBe(
      now + 3600000,
    );
  });
  it("加权回复速度排除未来、过期与无效时长", () => {
    const now = Date.parse("2026-10-13T00:00:00Z");
    const samples = [
      {
        completedAt: "2026-10-12T23:59:00Z",
        outputTokens: 100,
        turnSeconds: 20,
      },
      {
        completedAt: "2026-10-12T23:58:00Z",
        outputTokens: 100,
        turnSeconds: 5,
      },
      {
        completedAt: "2026-10-13T00:01:00Z",
        outputTokens: 10000,
        turnSeconds: 1,
      },
      {
        completedAt: "2026-10-12T23:44:00Z",
        outputTokens: 10000,
        turnSeconds: 1,
      },
      {
        completedAt: "2026-10-12T23:59:00Z",
        outputTokens: 10000,
        turnSeconds: 0,
      },
    ];
    expect(replySpeed(samples, now)).toEqual({
      sampleCount: 2,
      tokensPerSecond: 8,
    });
    expect(replySpeed(samples, now + 960000)).toBeNull();
  });
});
