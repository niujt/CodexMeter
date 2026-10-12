import { computed, onMounted, onUnmounted, reactive, watch } from "vue";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import {
  defaultPreferences,
  nextDisplayDeadline,
  type Bootstrap,
  type Preferences,
  type Snapshot,
  type PermissionEvent,
} from "./types";
export function useDesktop(floating = false) {
  let disposed = false,
    timer: ReturnType<typeof setTimeout> | undefined;
  const stops: (() => void)[] = [];
  const system = window.matchMedia("(prefers-color-scheme: dark)");
  const state = reactive({
    snapshot: null as Snapshot | null,
    preferences: { ...defaultPreferences, followedPaths: [] } as Preferences,
    permissions: [] as PermissionEvent[],
    hookStatus: "未安装",
    busy: false,
    error: "",
    status: "",
    now: Date.now(),
    nativeVisible: true,
    systemDark: system.matches,
    lowPower: false,
  });
  const dark = computed(
    () =>
      state.preferences.appearance === "dark" ||
      (state.preferences.appearance === "system" && state.systemDark),
  );
  const icon = computed(
    () =>
      `/icons/${state.preferences.iconStyle}-${dark.value ? "dark" : "light"}.png`,
  );
  function schedule() {
    clearTimeout(timer);
    state.now = Date.now();
    if (!state.nativeVisible || document.hidden) return;
    const next = nextDisplayDeadline(state.snapshot, state.now);
    if (next !== null)
      timer = setTimeout(
        schedule,
        Math.max(25, Math.min(next - state.now, 2_147_483_000)),
      );
  }
  function fail(error: unknown) {
    state.error = String(error);
  }
  async function command<T>(
    name: string,
    args?: Record<string, unknown>,
  ): Promise<T> {
    if (!isTauri())
      throw new Error("浏览器预览无法访问本机数据，请使用桌面应用。");
    return invoke<T>(name, args);
  }
  async function refresh(force = false) {
    if (state.busy) return;
    state.busy = true;
    state.error = "";
    try {
      state.snapshot = await command<Snapshot>("read_usage", { force });
      state.status = "";
      schedule();
    } catch (error) {
      fail(error);
    } finally {
      state.busy = false;
    }
  }
  async function choose() {
    try {
      if (!isTauri())
        throw new Error("浏览器预览无法读取本机数据，请使用桌面应用。");
      const path = await open({
        directory: true,
        multiple: false,
        title: "选择 Codex 主目录或会话目录",
      });
      if (typeof path !== "string") return;
      state.busy = true;
      state.error = "";
      state.snapshot = null;
      state.snapshot = await command<Snapshot>("select_directory", { path });
      await bootstrap();
      schedule();
    } catch (error) {
      fail(error);
    } finally {
      state.busy = false;
    }
  }
  async function updatePreferences(preferences: Preferences) {
    try {
      state.preferences = await command<Preferences>("save_preferences", {
        preferences,
      });
      schedule();
    } catch (error) {
      fail(error);
      throw error;
    }
  }
  async function bootstrap() {
    const data = await command<Bootstrap>("get_app_state");
    state.preferences = data.preferences;
    if (!floating && !data.preferencesSaved) {
      const legacy = localStorage.getItem("codex-health-appearance");
      if (legacy === "system" || legacy === "light" || legacy === "dark") {
        await updatePreferences({ ...state.preferences, appearance: legacy });
      }
    }
    state.snapshot = data.snapshot;
    state.permissions = data.permissions;
    state.hookStatus = data.hookStatus;
    state.lowPower = data.lowPower;
    state.nativeVisible = floating ? data.floatingVisible : data.mainVisible;
    schedule();
  }
  function systemChanged(event: MediaQueryListEvent) {
    state.systemDark = event.matches;
  }
  const visibleChanged = () => schedule();
  onMounted(async () => {
    system.addEventListener("change", systemChanged);
    document.addEventListener("visibilitychange", visibleChanged);
    if (!isTauri()) return;
    try {
      const register = async <T>(
        name: string,
        callback: (payload: T) => void,
      ) => {
        const stop = await listen<T>(name, (event) => callback(event.payload));
        if (disposed) stop();
        else stops.push(stop);
      };
      await Promise.all([
        register<Snapshot>("usage-updated", (payload) => {
          state.snapshot = payload;
          state.busy = false;
          state.error = "";
          schedule();
        }),
        register<void>("usage-invalidated", () => {
          state.snapshot = null;
          state.busy = true;
          schedule();
        }),
        register<Preferences>("preferences-updated", (payload) => {
          state.preferences = payload;
          schedule();
        }),
        register<PermissionEvent[]>("permissions-updated", (payload) => {
          state.permissions = payload;
        }),
        register<string>("usage-error", (payload) => {
          state.error = payload;
          state.busy = false;
        }),
        register<boolean>("visibility-changed", (payload) => {
          state.nativeVisible = payload;
          schedule();
        }),
      ]);
      if (!disposed) await bootstrap();
    } catch (error) {
      if (!disposed) fail(error);
    }
  });
  watch(() => state.snapshot, schedule);
  onUnmounted(() => {
    disposed = true;
    clearTimeout(timer);
    stops.forEach((stop) => stop());
    system.removeEventListener("change", systemChanged);
    document.removeEventListener("visibilitychange", visibleChanged);
  });
  return {
    state,
    dark,
    icon,
    command,
    refresh,
    choose,
    updatePreferences,
    bootstrap,
    fail,
  };
}
export type DesktopClient = ReturnType<typeof useDesktop>;
