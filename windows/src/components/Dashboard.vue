<script setup lang="ts">
import { computed, ref, watch, onMounted, onUnmounted } from "vue";
import { save, open } from "@tauri-apps/plugin-dialog";
import { writeFile } from "@tauri-apps/plugin-fs";
import {
  House,
  ChartNoAxesCombined,
  Cpu,
  Folder,
  Crosshair,
  History,
  RefreshCw,
  Receipt,
  Settings,
  ShieldCheck,
  FolderOpen,
  FolderPlus,
  Copy,
  Pin,
} from "@lucide/vue";
import { useDesktop } from "../desktop";
import {
  tokens,
  exact,
  projectName,
  replySpeed,
  remainingQuota,
  duration,
  hours,
  type Ranked,
  type ResetEvent,
} from "../types";
import { receiptPNG } from "../receipt";
import TrendChart from "./TrendChart.vue";
import Modal from "./Modal.vue";
import SettingsModal from "./SettingsModal.vue";
import PermissionCenter from "./PermissionCenter.vue";
const desktop = useDesktop(),
  state = desktop.state;
const sections = [
  { name: "健康报告", icon: House },
  { name: "使用趋势", icon: ChartNoAxesCombined },
  { name: "模型与效率", icon: Cpu },
  { name: "项目与用量", icon: Folder },
  { name: "预测与风险", icon: Crosshair },
  { name: "历史记录", icon: History },
];
const section = ref("健康报告"),
  settings = ref(false),
  receipt = ref<string | null>(null),
  receiptBytes = ref<Uint8Array | null>(null);
const granularity = ref("daily"),
  projectRange = ref("week"),
  fullPaths = ref(false),
  selectedProject = ref<Ranked | null>(null);
const historyDays = ref(30),
  historyModel = ref("全部"),
  historyProject = ref("全部"),
  filter = ref(""),
  page = ref(1);
const resetEvents = ref<ResetEvent[]>([]),
  resetBusy = ref(false),
  resetError = ref(""),
  resetLoaded = ref(false),
  showAllResets = ref(false);
const snapshot = computed(() => state.snapshot),
  remaining = computed(() =>
    remainingQuota(snapshot.value?.sevenDayRate ?? null, state.now),
  );
const speed = computed(() =>
  replySpeed(snapshot.value?.replySpeedSamples ?? [], state.now),
);
const prediction = computed(() =>
  remaining.value === null ? null : snapshot.value?.prediction,
);
const health = computed(() =>
  remaining.value === null
    ? "等待新周期数据"
    : (prediction.value?.health ?? "样本不足"),
);
const subtitles: Record<string, string> = {
  健康报告: "本机 Codex 用量、额度和近期效率。",
  使用趋势: "按 Token 计数增量归属实际发生的日期和小时。",
  模型与效率: "有效轮次统计可配对的用户消息与最终回答；耗时为端到端时长。",
  项目与用量: "按会话工作目录归类；不会读取项目源码。",
  预测与风险: "按 1 / 6 / 24 小时额度变化加权；样本不足时采用周期平均速度。",
  历史记录: "按小时、模型和目录汇总最近 30 天 Token 增量。",
};
const points = computed(() =>
  granularity.value === "daily"
    ? (snapshot.value?.dailyUsage ?? [])
    : (snapshot.value?.hourlyUsage ?? []),
);
const projects = computed(() => {
  const rows =
    projectRange.value === "today"
      ? snapshot.value?.todayProjects
      : projectRange.value === "month"
        ? snapshot.value?.monthProjects
        : snapshot.value?.projects;
  const values = [...(rows ?? [])];
  for (const path of state.preferences.followedPaths)
    if (!values.some((r) => r.name === path))
      values.push({
        name: path,
        tokens: 0,
        sessions: 0,
        requests: 0,
        averageTurnSeconds: null,
        cacheHitRate: null,
        lastActive: null,
      });
  return values;
});
const projectTotal = computed(() =>
  projects.value.reduce((sum, r) => sum + r.tokens, 0),
);
const models = computed(
  () =>
    snapshot.value?.models.filter(
      (m) => !m.name.toLowerCase().includes("spark"),
    ) ?? [],
);
const modelTotal = computed(() =>
  models.value.reduce((sum, m) => sum + m.tokens, 0),
);
const modelOptions = computed(() => [
    "全部",
    ...new Set(snapshot.value?.records.map((r) => r.model)),
  ]),
  projectOptions = computed(() => [
    "全部",
    ...new Set(snapshot.value?.records.map((r) => r.project)),
  ]);
const records = computed(
  () =>
    snapshot.value?.records.filter(
      (r) =>
        Date.parse(r.date) >= state.now - historyDays.value * 86_400_000 &&
        (historyModel.value === "全部" || r.model === historyModel.value) &&
        (historyProject.value === "全部" ||
          r.project === historyProject.value) &&
        `${r.project} ${r.model}`
          .toLowerCase()
          .includes(filter.value.toLowerCase()),
    ) ?? [],
);
const visibleRecords = computed(() =>
    records.value.slice((page.value - 1) * 50, page.value * 50),
  ),
  recordTotal = computed(() =>
    records.value.reduce((sum, r) => sum + r.tokens, 0),
  );
const projectRecords = computed(
  () =>
    snapshot.value?.records.filter(
      (r) => r.project === selectedProject.value?.name,
    ) ?? [],
);
watch(
  () => snapshot.value?.contextId,
  () => {
    resetEvents.value = [];
    resetLoaded.value = false;
    resetError.value = "";
    showAllResets.value = false;
  },
);
watch(
  () => snapshot.value?.dataPath,
  () => {
    selectedProject.value = null;
    historyModel.value = "全部";
    historyProject.value = "全部";
    page.value = 1;
  },
);
const unread = computed(
  () =>
    state.permissions.filter(
      (e) => e.status === "new" && e.attention !== "info",
    ).length,
);
function changeSection(name: string) {
  section.value = name;
  page.value = 1;
}
function key(event: KeyboardEvent) {
  if (
    event.target instanceof HTMLInputElement ||
    event.target instanceof HTMLSelectElement ||
    settings.value ||
    receipt.value ||
    selectedProject.value
  )
    return;
  if ((event.ctrlKey || event.metaKey) && /^[1-6]$/.test(event.key)) {
    event.preventDefault();
    changeSection(sections[Number(event.key) - 1]!.name);
  }
}
onMounted(() => window.addEventListener("keydown", key));
onUnmounted(() => {
  window.removeEventListener("keydown", key);
  closeReceipt();
});
async function preview() {
  if (!snapshot.value) return;
  try {
    closeReceipt();
    const data = await receiptPNG(snapshot.value);
    receiptBytes.value = data;
    receipt.value = URL.createObjectURL(
      new Blob([data as BlobPart], { type: "image/png" }),
    );
  } catch (error) {
    desktop.fail(error);
  }
}
function closeReceipt() {
  if (receipt.value) URL.revokeObjectURL(receipt.value);
  receipt.value = null;
  receiptBytes.value = null;
}
async function exportReceipt() {
  if (!receiptBytes.value) return;
  try {
    const path = await save({
      defaultPath: `Codex-Health-周用量-${snapshot.value?.dailyUsage.at(-1)?.date}.png`,
      filters: [{ name: "PNG 图片", extensions: ["png"] }],
    });
    if (!path) return;
    await writeFile(path, receiptBytes.value);
    state.status = "小票已保存";
    closeReceipt();
  } catch (error) {
    desktop.fail(error);
  }
}
async function addProject() {
  try {
    const path = await open({
      directory: true,
      multiple: false,
      title: "添加关注项目目录（仅保存路径）",
    });
    if (
      typeof path === "string" &&
      !state.preferences.followedPaths.includes(path)
    )
      await desktop.updatePreferences({
        ...state.preferences,
        followedPaths: [...state.preferences.followedPaths, path].sort(),
      });
  } catch (error) {
    desktop.fail(error);
  }
}
async function removeProject(path: string) {
  await desktop.updatePreferences({
    ...state.preferences,
    followedPaths: state.preferences.followedPaths.filter((p) => p !== path),
  });
}
async function openProject(path: string) {
  try {
    await desktop.command("open_project", { path });
  } catch (error) {
    desktop.fail(error);
  }
}
async function copy(path: string) {
  try {
    await navigator.clipboard.writeText(path);
    state.status = "路径已复制";
  } catch {
    state.error = "无法复制路径，请选中完整路径后复制。";
  }
}
async function resets() {
  if (resetBusy.value) return;
  resetBusy.value = true;
  resetError.value = "";
  const context = snapshot.value?.contextId;
  try {
    const events = await desktop.command<ResetEvent[]>("get_reset_history");
    if (snapshot.value?.contextId !== context)
      throw new Error("账户或目录已变化，请重新查询。");
    resetEvents.value = events;
    resetLoaded.value = true;
  } catch (error) {
    resetError.value = String(error);
  } finally {
    resetBusy.value = false;
  }
}
function resetTitle(kind: string) {
  return kind === "granted"
    ? "已获得重置次数"
    : ["used", "redeemed"].includes(kind)
      ? "已使用重置次数"
      : "其他重置记录";
}
</script>
<template>
  <div class="shell" :data-theme="state.preferences.appearance">
    <aside>
      <div class="brand">
        <img :src="desktop.icon.value" alt="Codex Health" /><span
          >Codex Health</span
        >
      </div>
      <div class="side-label">用量</div>
      <nav aria-label="用量页面">
        <button
          v-for="item in sections"
          :key="item.name"
          :class="{ selected: section === item.name }"
          :aria-current="section === item.name ? 'page' : undefined"
          @click="changeSection(item.name)"
        >
          <component :is="item.icon" :size="18" /><span>{{ item.name }}</span>
        </button>
      </nav>
      <div class="side-footer">
        <ShieldCheck :size="15" />本机统计<span v-if="unread" class="unread">{{
          unread
        }}</span>
      </div>
    </aside>
    <div class="main">
      <header>
        <span>{{ section }}</span>
        <div class="toolbar">
          <button
            @click="preview"
            :disabled="!snapshot || state.busy"
            title="导出周用量小票"
          >
            <Receipt :size="17" />导出小票</button
          ><button
            @click="desktop.refresh()"
            :disabled="!state.preferences.directory || state.busy"
            title="刷新本机用量"
          >
            <RefreshCw :size="17" :class="{ spinning: state.busy }" />刷新
          </button>
          <details class="refresh-menu">
            <summary aria-label="刷新选项">⌄</summary>
            <button @click="desktop.refresh(true)" :disabled="state.busy">
              重新读取全部记录
            </button>
          </details>
          <span class="toolbar-rule"></span
          ><button @click="settings = true" title="设置" aria-label="设置">
            <Settings :size="18" />
          </button>
        </div>
      </header>
      <main>
        <div v-if="state.error" class="notice" role="alert">
          {{ state.error }}
        </div>
        <div v-if="state.status" class="notice" role="status">
          {{ state.status }}
        </div>
        <div v-if="state.busy" class="loading" role="status">
          <RefreshCw :size="14" class="spinning" />正在检查用量文件…
        </div>
        <div class="page-heading">
          <div>
            <h1>{{ section }}</h1>
            <p>{{ subtitles[section] }}</p>
            <small v-if="snapshot"
              >最近检查 {{ new Date(snapshot.observedAt).toLocaleString() }} ·
              最新记录
              {{
                snapshot.lastUpdated
                  ? new Date(snapshot.lastUpdated).toLocaleString()
                  : "暂无"
              }}</small
            >
          </div>
          <span v-if="snapshot" class="health"
            ><ShieldCheck :size="15" />{{ health }}</span
          >
        </div>
        <div v-if="!snapshot" class="empty">
          <img
            :src="desktop.icon.value"
            width="76"
            height="76"
            alt="Codex Health"
          />
          <h2>让每一份用量清晰可见</h2>
          <p>
            {{
              state.preferences.directory
                ? "等待当前目录读取结果。"
                : "选择 Codex 主目录或会话目录。"
            }}<br />所有统计在本机完成。
          </p>
          <button
            class="primary"
            @click="desktop.choose"
            :disabled="state.busy"
          >
            <FolderOpen :size="17" />选择 Codex 数据目录</button
          ><small>Windows 通常位于用户目录下的 .codex</small>
        </div>
        <template v-else
          ><div v-if="snapshot.warnings.length" class="notice">
            {{ snapshot.warnings.join("；") }}
          </div>
          <template v-if="section === '健康报告'"
            ><div class="metrics">
              <div>
                <label>7 天剩余额度</label
                ><strong>{{
                  remaining === null ? "—" : `${remaining}%`
                }}</strong
                ><progress
                  v-if="remaining !== null"
                  :value="remaining"
                  max="100"
                /><small>{{
                  remaining === null
                    ? snapshot.quotaWaitingMessage
                    : `重置于 ${new Date(snapshot.sevenDayRate!.resetsAt).toLocaleString()}`
                }}</small
                ><small v-if="snapshot.primaryRate?.windowMinutes === 300">
                  5 小时剩余
                  {{
                    remainingQuota(snapshot.primaryRate, state.now) === null
                      ? "—"
                      : `${remainingQuota(snapshot.primaryRate, state.now)}%`
                  }} </small
                ><small v-if="snapshot.sparkRate"
                  >Spark 剩余
                  {{
                    remainingQuota(snapshot.sparkRate, state.now) ?? "—"
                  }}%</small
                >
              </div>
              <div>
                <label>今日用量</label
                ><strong>{{ tokens(snapshot.today.total) }}</strong
                ><small
                  >输入 {{ tokens(snapshot.today.input) }} · 输出
                  {{ tokens(snapshot.today.output) }}</small
                >
              </div>
              <div>
                <label>近 7 天用量</label
                ><strong>{{ tokens(snapshot.lastSevenDays.total) }}</strong
                ><small>近 7 个自然日 Token 消耗</small>
              </div>
              <div>
                <label>平均回复速度</label
                ><strong
                  >{{ speed ? speed.tokensPerSecond.toFixed(1) : "—"
                  }}<span v-if="speed" class="unit"> tokens/s</span></strong
                ><small>{{
                  speed
                    ? `近 15 分钟 · ${speed.sampleCount} 个有效轮次`
                    : "近 15 分钟暂无样本"
                }}</small>
              </div>
            </div>
            <section class="flat">
              <div class="section-heading">
                <h2>使用趋势</h2>
                <small>近 7 天 · Token</small>
              </div>
              <TrendChart :days="snapshot.dailyUsage" />
            </section>
            <div class="two-columns">
              <section class="flat">
                <div class="section-heading">
                  <h2>模型与效率</h2>
                  <small>近 7 天</small>
                </div>
                <div v-for="m in models.slice(0, 3)" :key="m.name" class="rank">
                  <div>
                    <span>{{ m.name }}</span
                    ><span>{{ tokens(m.tokens) }}</span>
                  </div>
                  <progress
                    :value="m.tokens"
                    :max="Math.max(1, snapshot.lastSevenDays.total)"
                  /><small
                    >{{ m.requests }} 个有效轮次 · 平均
                    {{ duration(m.averageTurnSeconds) }}</small
                  >
                </div>
                <p v-if="!models.length" class="muted">暂无模型记录</p>
              </section>
              <section class="flat">
                <div class="section-heading">
                  <h2>活跃项目</h2>
                  <small>近 7 天</small>
                </div>
                <button
                  v-for="p in snapshot.projects.slice(0, 4)"
                  :key="p.name"
                  class="project-row"
                  @click="selectedProject = p"
                >
                  <Folder :size="16" /><span :title="p.name">{{
                    projectName(p.name)
                  }}</span
                  ><small
                    >{{
                      Math.round(
                        (p.tokens / Math.max(1, snapshot.lastSevenDays.total)) *
                          100,
                      )
                    }}%</small
                  >
                </button>
                <p v-if="!snapshot.projects.length" class="muted">
                  暂无项目记录
                </p>
              </section>
            </div>
            <div class="footer-metrics">
              <div><label>本机记录</label>{{ snapshot.fileCount }} 个文件</div>
              <div>
                <label>本月用量</label>{{ tokens(snapshot.thisMonth.total) }}
              </div>
              <div>
                <label>当前上下文</label
                >{{
                  snapshot.contextWindow
                    ? `${tokens(snapshot.currentContextUsed)} / ${tokens(snapshot.contextWindow)}`
                    : "暂无"
                }}
              </div>
              <div><label>会话</label>{{ snapshot.sessionCount }} 个</div>
            </div>
            <PermissionCenter :desktop="desktop" />
          </template>
          <template v-else-if="section === '使用趋势'"
            ><div class="filter-row">
              <div class="segments">
                <button
                  :class="{ active: granularity === 'daily' }"
                  @click="granularity = 'daily'"
                >
                  按天</button
                ><button
                  :class="{ active: granularity === 'hourly' }"
                  @click="granularity = 'hourly'"
                >
                  近 24 小时
                </button>
              </div>
              <small
                >总计
                {{ tokens(points.reduce((sum, p) => sum + p.tokens, 0)) }}
                Token</small
              >
            </div>
            <section class="flat">
              <div class="section-heading">
                <h2>
                  {{ granularity === "daily" ? "近 7 天" : "近 24 小时" }} Token
                  趋势
                </h2>
                <small
                  >峰值
                  {{
                    tokens(Math.max(0, ...points.map((p) => p.tokens)))
                  }}</small
                >
              </div>
              <TrendChart
                v-if="points.length"
                :days="points"
                :hourly="granularity === 'hourly'"
              />
              <p v-else class="muted">暂无趋势样本</p>
            </section>
            <div class="metrics compact">
              <div>
                <label>今天</label
                ><strong>{{ tokens(snapshot.today.total) }}</strong>
              </div>
              <div>
                <label>近 7 天</label
                ><strong>{{ tokens(snapshot.lastSevenDays.total) }}</strong>
              </div>
              <div>
                <label>本月</label
                ><strong>{{ tokens(snapshot.thisMonth.total) }}</strong>
              </div>
            </div></template
          >
          <template v-else-if="section === '模型与效率'"
            ><section v-for="m in models" :key="m.name" class="flat">
              <div class="section-heading">
                <h2><Cpu :size="17" />{{ m.name }}</h2>
                <span
                  >{{ Math.round((m.tokens / Math.max(1, modelTotal)) * 100) }}%
                  占比</span
                >
              </div>
              <progress :value="m.tokens" :max="Math.max(1, modelTotal)" />
              <div class="model-metrics">
                <div>
                  <label>Token</label><b>{{ tokens(m.tokens) }}</b>
                </div>
                <div>
                  <label>有效轮次</label><b>{{ m.requests }} 次</b>
                </div>
                <div>
                  <label>平均轮次耗时</label
                  ><b>{{ duration(m.averageTurnSeconds) }}</b>
                </div>
                <div title="缓存命中率 = cached_input_tokens / input_tokens">
                  <label>缓存命中率</label
                  ><b>{{
                    m.cacheHitRate === null
                      ? "样本不足"
                      : `${(m.cacheHitRate * 100).toFixed(1)}%`
                  }}</b>
                </div>
              </div>
            </section>
            <p v-if="!models.length" class="muted">暂无模型样本</p></template
          >
          <template v-else-if="section === '项目与用量'"
            ><div class="filter-row">
              <div class="segments">
                <button
                  v-for="range in [
                    ['today', '今天'],
                    ['week', '近 7 天'],
                    ['month', '近 30 天'],
                  ]"
                  :key="range[0]"
                  :class="{ active: projectRange === range[0] }"
                  @click="projectRange = range[0]!"
                >
                  {{ range[1] }}
                </button>
              </div>
              <label class="check-row"
                ><input v-model="fullPaths" type="checkbox" />完整路径</label
              ><button @click="addProject">
                <FolderPlus :size="15" />添加项目目录
              </button>
            </div>
            <small
              >{{ projects.length }} 个项目 ·
              {{ tokens(projectTotal) }} Token</small
            >
            <section
              v-for="p in projects"
              :key="p.name"
              class="project-card flat"
            >
              <button class="project-open" @click="selectedProject = p">
                <Folder :size="18" />
                <div>
                  <b>{{ fullPaths ? p.name : projectName(p.name) }}</b
                  ><small
                    >{{ p.sessions }} 个会话 ·
                    {{
                      p.lastActive
                        ? `最近活动 ${new Date(p.lastActive).toLocaleString()}`
                        : "暂无记录"
                    }}</small
                  >
                </div>
                <span
                  >{{ tokens(p.tokens) }} ·
                  {{
                    Math.round((p.tokens / Math.max(1, projectTotal)) * 100)
                  }}%</span
                >
              </button>
              <div class="actions">
                <small v-if="state.preferences.followedPaths.includes(p.name)"
                  ><Pin :size="12" />已关注</small
                ><button @click="copy(p.name)">
                  <Copy :size="13" />复制路径</button
                ><button @click="openProject(p.name)">打开目录</button
                ><button
                  v-if="state.preferences.followedPaths.includes(p.name)"
                  @click="removeProject(p.name)"
                >
                  取消关注
                </button>
              </div>
            </section>
            <p v-if="!projects.length" class="muted">
              暂未识别到项目路径；可手动添加关注目录。
            </p></template
          >
          <template v-else-if="section === '预测与风险'"
            ><template v-if="remaining !== null"
              ><div class="metrics risk">
                <div>
                  <label>7 天额度</label><strong>剩余 {{ remaining }}%</strong
                  ><progress :value="remaining" max="100" /><small
                    >重置于
                    {{
                      new Date(snapshot.sevenDayRate!.resetsAt).toLocaleString()
                    }}</small
                  >
                </div>
                <div>
                  <label>续航预测</label
                  ><strong>{{
                    hours(prediction?.remainingHours ?? null)
                  }}</strong
                  ><span>{{
                    prediction?.remainingHours == null
                      ? "继续使用后会形成预测"
                      : prediction.willExhaust
                        ? "可能在重置前耗尽"
                        : "预计可支撑到重置"
                  }}</span
                  ><small
                    >当前平均消耗
                    {{
                      prediction?.percentPerHour == null
                        ? "—"
                        : `${prediction.percentPerHour.toFixed(2)}% / 小时`
                    }}</small
                  >
                </div>
              </div>
              <section class="flat">
                <h2>风险说明</h2>
                <p>{{ health }}</p>
                <p>
                  下次重置：{{
                    new Date(snapshot.sevenDayRate!.resetsAt).toLocaleString()
                  }}
                </p>
                <p>
                  {{
                    prediction?.windowsUsed.length
                      ? `已使用近 ${prediction.windowsUsed.join(" / ")} 小时的额度变化样本。`
                      : "暂无连续变化样本，使用本周期平均速度。"
                  }}
                </p>
              </section></template
            >
            <div v-else class="empty">
              <Crosshair :size="36" />
              <h2>{{ snapshot.quotaWaitingMessage }}</h2>
              <p>{{ snapshot.accountStatus }}</p>
            </div></template
          >
          <template v-else
            ><section class="flat">
              <div class="section-heading">
                <h2>真实重置历史</h2>
                <button @click="resets" :disabled="resetBusy">
                  {{
                    resetBusy
                      ? "读取中…"
                      : resetLoaded
                        ? "刷新重置历史"
                        : "读取重置历史"
                  }}
                </button>
              </div>
              <p v-if="resetError" class="notice" role="alert">
                {{ resetError }}
              </p>
              <p v-if="!resetLoaded" class="muted">
                点击后使用所选目录的当前登录向 ChatGPT
                查询，仅查询，不消耗重置次数。
              </p>
              <p v-else-if="!resetEvents.length" class="muted">
                过去 30 天没有重置次数记录。
              </p>
              <div
                v-for="event in showAllResets
                  ? resetEvents
                  : resetEvents.slice(0, 10)"
                :key="event.id"
                class="timeline-row"
              >
                <span>{{ resetTitle(event.kind) }}</span
                ><small>{{
                  new Date(event.occurred_at).toLocaleString()
                }}</small>
              </div>
              <button
                v-if="resetEvents.length > 10"
                @click="showAllResets = !showAllResets"
              >
                {{
                  showAllResets
                    ? "收起"
                    : `更多（剩余 ${resetEvents.length - 10} 条）`
                }}
              </button>
            </section>
            <section v-if="snapshot.rateTimeline.length" class="flat">
              <h2>7 天额度周期时间线</h2>
              <div
                v-for="(cycle, index) in snapshot.rateTimeline.slice(0, 8)"
                :key="`${cycle.limitId}-${cycle.resetsAt}`"
                class="cycle-row"
              >
                <div>
                  <b>{{
                    index === 0 ? "当前额度周期" : "已观察到的额度周期"
                  }}</b
                  ><small
                    >最近采样 {{ new Date(cycle.date).toLocaleString() }} · 已用
                    {{ cycle.usedPercent.toFixed(0) }}% · 本机已记录
                    {{ tokens(cycle.tokens) }} Token</small
                  >
                </div>
                <small
                  >重置于 {{ new Date(cycle.resetsAt).toLocaleString() }}</small
                >
              </div>
            </section>
            <section class="flat">
              <div class="filter-row">
                <div class="segments">
                  <button
                    v-for="days in [7, 30]"
                    :key="days"
                    :class="{ active: historyDays === days }"
                    @click="
                      historyDays = days;
                      page = 1;
                    "
                  >
                    近 {{ days }} 天
                  </button>
                </div>
                <select
                  v-model="historyModel"
                  @change="page = 1"
                  aria-label="历史模型"
                >
                  <option v-for="m in modelOptions" :key="m">
                    {{ m }}
                  </option></select
                ><select
                  v-model="historyProject"
                  @change="page = 1"
                  aria-label="历史项目"
                >
                  <option v-for="p in projectOptions" :key="p" :value="p">
                    {{ p === "全部" ? p : projectName(p) }}
                  </option></select
                ><input
                  v-model="filter"
                  @input="page = 1"
                  placeholder="搜索项目或模型"
                  aria-label="搜索项目或模型"
                />
              </div>
              <small
                >{{ records.length }} 条 ·
                {{ tokens(recordTotal) }} Token</small
              >
              <div class="table-scroll">
                <table>
                  <thead>
                    <tr>
                      <th>时间</th>
                      <th>项目</th>
                      <th>模型</th>
                      <th>Token</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      v-for="r in visibleRecords"
                      :key="`${r.date}-${r.project}-${r.model}`"
                    >
                      <td>{{ new Date(r.date).toLocaleString() }}</td>
                      <td :title="r.project">{{ projectName(r.project) }}</td>
                      <td>{{ r.model }}</td>
                      <td>{{ tokens(r.tokens) }}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <p v-if="!records.length" class="muted">没有符合条件的本地记录</p>
              <div v-if="records.length > 50" class="pagination">
                <button :disabled="page <= 1" @click="page--">上一页</button
                ><small>{{ page }} / {{ Math.ceil(records.length / 50) }}</small
                ><button
                  :disabled="page * 50 >= records.length"
                  @click="page++"
                >
                  下一页
                </button>
              </div>
            </section></template
          >
        </template>
      </main>
    </div>
    <SettingsModal
      v-if="settings"
      :desktop="desktop"
      @close="settings = false"
    />
    <Modal v-if="receipt" title="周用量小票" @close="closeReceipt"
      ><div class="receipt-scroll">
        <img :src="receipt" alt="纯白周用量小票预览" />
      </div>
      <button class="primary full-width" @click="exportReceipt">
        保存 PNG…
      </button></Modal
    >
    <Modal
      v-if="selectedProject"
      :title="projectName(selectedProject.name)"
      wide
      @close="selectedProject = null"
      ><p class="path selectable">{{ selectedProject.name }}</p>
      <div class="actions">
        <button @click="copy(selectedProject.name)">复制路径</button
        ><button @click="openProject(selectedProject.name)">打开目录</button>
      </div>
      <div class="metrics compact">
        <div>
          <label>Token</label
          ><strong>{{ tokens(selectedProject.tokens) }}</strong>
        </div>
        <div>
          <label>会话</label><strong>{{ selectedProject.sessions }}</strong>
        </div>
        <div>
          <label>记录</label><strong>{{ projectRecords.length }}</strong>
        </div>
      </div>
      <div class="table-scroll">
        <table>
          <thead>
            <tr>
              <th>时间</th>
              <th>模型</th>
              <th>Token</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="r in projectRecords.slice(0, 100)"
              :key="`${r.date}-${r.model}`"
            >
              <td>{{ new Date(r.date).toLocaleString() }}</td>
              <td>{{ r.model }}</td>
              <td>{{ exact(r.tokens) }}</td>
            </tr>
          </tbody>
        </table>
      </div></Modal
    >
  </div>
</template>
