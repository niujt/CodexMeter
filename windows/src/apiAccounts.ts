import { reactive } from "vue";

export type ApiProvider = "openai" | "deepseek";
export interface ApiSnapshot {
  provider: ApiProvider;
  checkedAt: string;
  periodStart: string | null;
  costs: Record<string, string> | null;
  usage: {input: string; cachedInput: string; output: string; requests: string} | null;
  limit: {configured: boolean; amount: string | null; enforcing: boolean} | null;
  budgetRemaining: string | null;
  balances: {currency: string; total: string; granted: string; toppedUp: string}[] | null;
  isAvailable: boolean | null;
  warnings: string[];
}
export interface ApiStatus { configured: boolean; snapshot: ApiSnapshot | null; error: string | null; busy: boolean }
type Command = <T>(name: string, args?: Record<string, unknown>) => Promise<T>;
const empty = (): ApiStatus => ({configured: false, snapshot: null, error: null, busy: false});
const message = (error: unknown) => typeof error === "string" ? error : "无法访问桌面 API 服务，请重试。";

export function useApiAccounts(command: Command) {
  const states = reactive<Record<ApiProvider, ApiStatus>>({openai: empty(), deepseek: empty()});
  const generations: Record<ApiProvider, number> = {openai: 0, deepseek: 0};
  async function status(provider: ApiProvider) {
    if (states[provider].busy) return;
    const ticket = ++generations[provider];
    states[provider].busy = true;
    try {
      const result = await command<ApiStatus>("api_status", {provider});
      if (ticket === generations[provider]) Object.assign(states[provider], result);
    } catch (error) {
      if (ticket === generations[provider]) Object.assign(states[provider], empty(), {error: message(error)});
    } finally { if (ticket === generations[provider]) states[provider].busy = false; }
  }
  async function load(provider: ApiProvider, force = false) {
    if (states[provider].busy) return;
    const ticket = ++generations[provider];
    states[provider].busy = true;
    try {
      const result = await command<ApiStatus>("api_load", {provider, force});
      if (ticket === generations[provider]) Object.assign(states[provider], result);
    } catch (error) {
      // Network failures are returned as dated Status data; RPC errors can mean a vault failure.
      if (ticket === generations[provider]) Object.assign(states[provider], empty(), {error: message(error)});
    } finally { if (ticket === generations[provider]) states[provider].busy = false; }
  }
  async function save(provider: ApiProvider, text: string): Promise<boolean> {
    const ticket = ++generations[provider];
    states[provider].busy = true;
    try {
      const result = await command<ApiStatus>("api_save_key", {provider, text});
      if (ticket !== generations[provider]) return false;
      Object.assign(states[provider], result);
      return true;
    } catch (error) {
      if (ticket === generations[provider]) states[provider].error = message(error);
      return false;
    } finally { if (ticket === generations[provider]) states[provider].busy = false; }
  }
  async function openConsole(provider: ApiProvider) {
    try { await command("api_open_console", {provider}); }
    catch (error) { states[provider].error = message(error); }
  }
  return {states, status, load, save, openConsole};
}
export type ApiAccounts = ReturnType<typeof useApiAccounts>;
export function money(value: string | null | undefined, currency = "USD"): string {
  if (value == null || !value.trim() || !Number.isFinite(Number(value))) return "—";
  return new Intl.NumberFormat("zh-CN", {style: "currency", currency: currency.toUpperCase(), minimumFractionDigits: 2, maximumFractionDigits: 8}).format(Number(value));
}
export function count(value: string | undefined): string {
  if (value == null) return "—";
  try { return BigInt(value).toLocaleString("zh-CN"); } catch { return "—"; }
}
