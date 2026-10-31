import { describe, it, expect, vi } from "vitest";
import { useApiAccounts, money, count, type ApiStatus } from "./apiAccounts";
const status = (configured = true): ApiStatus => ({configured, snapshot: null, busy: false, error: null});
describe("独立 API 账户", () => {
  it("saves separate providers without putting keys in state", async () => {
    const command = vi.fn().mockResolvedValue(status());
    const accounts = useApiAccounts(command);
    await accounts.save("deepseek", "sk-synthetic-deepseek-0000");
    expect(accounts.states.deepseek.configured).toBe(true);
    expect(accounts.states.openai.configured).toBe(false);
    expect(JSON.stringify(accounts.states)).not.toContain("sk-synthetic");
    expect(command.mock.calls[0]).toEqual(["api_save_key", {provider: "deepseek", text: "sk-synthetic-deepseek-0000"}]);
  });
  it("discards an old in-flight account response after replacing a key", async () => {
    let finish!: (value: ApiStatus) => void;
    const command = vi.fn().mockImplementationOnce(() => new Promise<ApiStatus>(resolve => { finish = resolve; })).mockResolvedValueOnce(status());
    const accounts = useApiAccounts(command);
    const pending = accounts.load("deepseek");
    expect(accounts.states.deepseek.busy).toBe(true);
    await accounts.save("deepseek", "sk-synthetic-deepseek-0000");
    finish({...status(), error:"old account error"}); await pending;
    expect(accounts.states.deepseek.error).toBeNull();
    expect(accounts.states.deepseek.busy).toBe(false);
  });
  it("rejects duplicate loads and clears data on a credential RPC failure", async () => {
    let finish!: () => void;
    const command = vi.fn().mockImplementationOnce(() => new Promise<void>(resolve => { finish = resolve; })).mockRejectedValueOnce("凭据不可读");
    const accounts = useApiAccounts(command);
    const pending = accounts.load("openai");
    await accounts.load("openai"); expect(command).toHaveBeenCalledTimes(1);
    finish(); await pending;
    await accounts.load("openai");
    expect(accounts.states.openai.configured).toBe(false);
    expect(accounts.states.openai.snapshot).toBeNull();
    expect(accounts.states.openai.error).toBe("凭据不可读");
  });
  it("keeps a failed save from removing the existing credential", async () => {
    const command = vi.fn().mockResolvedValueOnce(status()).mockRejectedValueOnce("无法保存");
    const accounts = useApiAccounts(command);
    await accounts.status("openai");
    expect(await accounts.save("openai", "sk-synthetic-replacement-0000")).toBe(false);
    expect(accounts.states.openai.configured).toBe(true);
    expect(accounts.states.openai.error).toBe("无法保存");
  });
  it("formats missing amounts as unknown and integer counts without floating-point loss", () => {
    expect(money(null)).toBe("—"); expect(money("")).toBe("—");
    expect(money("NaN")).toBe("—"); expect(money("0", "CNY")).toContain("0.00");
    expect(money("0.12345678", "USD")).toContain("0.12345678");
    expect(count("9007199254740993")).toBe("9,007,199,254,740,993");
  });
});
