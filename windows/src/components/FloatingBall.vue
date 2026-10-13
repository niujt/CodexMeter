<script setup lang="ts">
import { computed, onMounted, onUnmounted } from "vue";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { isTauri } from "@tauri-apps/api/core";
import { X, RefreshCw } from "@lucide/vue";
import { useDesktop } from "../desktop";
import { quotaDisplay, tokens } from "../types";
const desktop = useDesktop(true),
  state = desktop.state;
const quota = computed(() => quotaDisplay(state.snapshot?.sevenDayRate ?? null, state.snapshot?.mainRateSampledAt, state.now));
const remaining = computed(() => quota.value.remaining);
const summaryRate = computed(
  () => state.snapshot?.primaryRate ?? state.snapshot?.sevenDayRate ?? null,
);
const summaryQuota = computed(() => quotaDisplay(summaryRate.value, state.snapshot?.primaryRate ? state.snapshot.primaryRateSampledAt : state.snapshot?.mainRateSampledAt, state.now));
const summaryRemaining = computed(() => summaryQuota.value.remaining);
let origin: { x: number; y: number } | null = null,
  dragging = false,
  disposed = false,
  unlisten: (() => void) | undefined,
  saveTimer: ReturnType<typeof setTimeout> | undefined;
function down(event: PointerEvent) {
  if (event.button === 0) {
    origin = { x: event.screenX, y: event.screenY };
    dragging = false;
  }
}
async function move(event: PointerEvent) {
  if (
    !origin ||
    dragging ||
    !(event.buttons & 1) ||
    Math.hypot(event.screenX - origin.x, event.screenY - origin.y) < 5 ||
    !isTauri()
  )
    return;
  dragging = true;
  origin = null;
  try {
    await getCurrentWindow().startDragging();
  } catch {
    dragging = false;
  }
}
async function show() {
  if (!dragging)
    try {
      await desktop.command("show_dashboard");
    } catch (error) {
      desktop.fail(error);
    }
}
async function hide() {
  try {
    await desktop.command("toggle_floating", { visible: false });
  } catch (error) {
    desktop.fail(error);
  }
}
onMounted(async () => {
  document.documentElement.classList.add("floating-window");
  if (isTauri()) {
    const stop = await getCurrentWindow().onMoved(() => {
      clearTimeout(saveTimer);
      saveTimer = setTimeout(() => {
        void desktop.command("save_floating_position").catch(desktop.fail);
      }, 400);
    });
    if (disposed) stop();
    else unlisten = stop;
  }
});
onUnmounted(() => {
  disposed = true;
  clearTimeout(saveTimer);
  unlisten?.();
  document.documentElement.classList.remove("floating-window");
});
</script>
<template>
  <div
    class="floating-surface"
    :class="{ summary: state.preferences.floatingStyle === 'summary' }"
    :data-theme="state.preferences.appearance"
  >
    <button
      v-if="state.preferences.floatingStyle === 'ball'"
      class="quota-ball"
      :style="{ '--quota': `${remaining ?? 0}%` }"
      :aria-label="`7 天剩余额度 ${remaining === null ? '暂无数据' : remaining + '%'}，双击打开健康报告`"
      :title="`${quota.label}${remaining === null && quota.lastRemaining !== null ? ` · 上次剩余 ${quota.lastRemaining}%` : ''} · 双击打开健康报告 · 拖动调整位置`"
      @pointerdown="down"
      @pointermove="move"
      @pointerup="origin = null"
      @dblclick="show"
      @keydown.enter="show"
    >
      <strong>{{ remaining === null ? "—" : remaining + "%" }}</strong
      ><span>{{ quota.stale ? '旧采样' : '本地采样' }}</span>
    </button>
    <section
      v-else
      class="floating-summary"
      @pointerdown="down"
      @pointermove="move"
      @pointerup="origin = null"
      @dblclick="show"
    >
      <div class="summary-heading">
        <img
          :src="desktop.icon.value"
          width="28"
          height="28"
          alt="Codex Health"
        /><b>Codex Health</b
        ><button @pointerdown.stop @click="hide" aria-label="关闭悬浮摘要">
          <X :size="14" />
        </button>
      </div>
      <div class="summary-metrics">
        <div>
          <small>今日用量</small
          ><b>{{ tokens(state.snapshot?.today.total ?? 0) }}</b>
        </div>
        <div>
          <small>近 7 天</small
          ><b>{{ tokens(state.snapshot?.lastSevenDays.total ?? 0) }}</b>
        </div>
      </div>
      <div class="summary-quota">
        <span>{{
          summaryRate?.windowMinutes === 300 ? "5 小时剩余额度" : "7 天剩余额度"
        }}</span
        ><strong>{{
          summaryRemaining === null ? "—" : summaryRemaining + "%"
        }}</strong>
      </div>
      <small v-if="summaryRate">{{ summaryQuota.label }}<template v-if="summaryRemaining === null && summaryQuota.lastRemaining !== null"> · 上次剩余 {{ summaryQuota.lastRemaining }}%</template></small>
      <progress
        v-if="summaryRemaining !== null"
        :value="summaryRemaining"
        max="100"
      /><small>{{
        state.snapshot?.contextWindow
          ? `当前上下文 ${tokens(state.snapshot.currentContextUsed)} / ${tokens(state.snapshot.contextWindow)}`
          : "等待上下文样本"
      }}</small>
      <div class="summary-footer">
        <small>低功耗共享刷新</small
        ><button
          @pointerdown.stop
          @click="desktop.refresh()"
          :disabled="state.busy"
          aria-label="刷新摘要"
        >
          <RefreshCw :size="14" />
        </button>
      </div>
    </section>
  </div>
</template>
<style>
html.floating-window,
html.floating-window body,
html.floating-window #app {
  background: transparent !important;
  margin: 0;
  overflow: hidden;
}
.floating-surface {
  --bg: #fff;
  --ink: #242424;
  --muted: #777;
  --line: #e4e4e4;
  --hover: #f1f1f1;
  --bar: #484848;
  width: 88px;
  height: 88px;
  display: grid;
  place-items: center;
  font-family: "Segoe UI", "Microsoft YaHei", sans-serif;
}
.floating-surface[data-theme="dark"] {
  --bg: #202020;
  --ink: #ededed;
  --muted: #aaa;
  --line: #414141;
  --hover: #353535;
  --bar: #ccc;
}
@media (prefers-color-scheme: dark) {
  .floating-surface[data-theme="system"] {
    --bg: #202020;
    --ink: #ededed;
    --muted: #aaa;
    --line: #414141;
    --hover: #353535;
    --bar: #ccc;
  }
}
.quota-ball {
  position: relative;
  width: 76px;
  height: 76px;
  padding: 0;
  border: 1px solid var(--line);
  border-radius: 50%;
  background: var(--bg);
  color: var(--ink);
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 2px;
  cursor: grab;
  user-select: none;
  touch-action: none;
  box-shadow: 0 2px 6px #0002;
}
.quota-ball:before {
  content: "";
  position: absolute;
  inset: 4px;
  border-radius: 50%;
  background: conic-gradient(var(--ink) var(--quota), var(--line) 0);
  mask: radial-gradient(farthest-side, transparent calc(100% - 2px), #000 0);
  pointer-events: none;
}
.quota-ball strong {
  font-size: 20px;
  line-height: 25px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.quota-ball span {
  font-size: 9px;
  color: var(--muted);
}
.floating-surface .quota-ball:hover {
  background: var(--bg);
}
.quota-ball:active {
  cursor: grabbing;
}
.quota-ball:focus-visible {
  outline: 2px solid var(--ink);
  outline-offset: 2px;
}
.floating-surface.summary {
  width: 300px;
  height: 245px;
  padding: 7px;
  color: var(--ink);
}
.floating-summary {
  width: 100%;
  height: 100%;
  border: 1px solid var(--line);
  border-radius: 15px;
  padding: 13px 15px;
  background: var(--bg);
  box-shadow: 0 2px 5px #0002;
  cursor: grab;
  user-select: none;
  touch-action: none;
}
.summary-heading,
.summary-footer,
.summary-quota {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.summary-heading > b {
  flex: 1;
  font-size: 13px;
}
.summary-heading button,
.summary-footer button {
  border: 0;
  padding: 3px;
  background: transparent;
}
.summary-metrics {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 20px;
  padding: 15px 0 12px;
  border-bottom: 1px solid var(--line);
}
.summary-metrics > div {
  display: flex;
  flex-direction: column;
  gap: 5px;
}
.summary-metrics b {
  font-size: 18px;
}
.summary-quota {
  padding: 10px 0 5px;
  font-size: 11px;
}
.summary-quota strong {
  font-size: 19px;
}
.floating-summary small {
  font-size: 10px;
  color: var(--muted);
}
.floating-summary > small {
  display: block;
  margin-top: 10px;
}
.summary-footer {
  margin-top: 8px;
}
</style>
