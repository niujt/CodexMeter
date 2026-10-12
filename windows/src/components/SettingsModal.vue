<script setup lang="ts">
import { ref, computed, reactive, watch } from "vue";
import Modal from "./Modal.vue";
import type { DesktopClient } from "../desktop";
import type { Preferences } from "../types";
import { FolderOpen } from "@lucide/vue";
const props = defineProps<{ desktop: DesktopClient }>();
const emit = defineEmits<{ close: [] }>();
const tab = ref("通用"),
  pending = ref(false),
  message = ref("");
const draft = reactive<Preferences>(
  JSON.parse(JSON.stringify(props.desktop.state.preferences)),
);
watch(
  () => props.desktop.state.preferences,
  (value) => {
    if (!pending.value) Object.assign(draft, JSON.parse(JSON.stringify(value)));
  },
);
const logo = computed(
  () =>
    `/icons/${draft.iconStyle}-${draft.appearance === "dark" || (draft.appearance === "system" && props.desktop.dark.value) ? "dark" : "light"}.png`,
);
let queued = false;
async function save() {
  queued = true;
  if (pending.value) return;
  pending.value = true;
  try {
    while (queued) {
      queued = false;
      await props.desktop.updatePreferences({
        ...draft,
        followedPaths: [...draft.followedPaths],
      });
    }
  } catch (error) {
    message.value = String(error);
  } finally {
    pending.value = false;
  }
}
async function set<K extends keyof Preferences>(key: K, value: Preferences[K]) {
  draft[key] = value;
  await save();
}
async function hook(remove = false) {
  if (
    remove &&
    !window.confirm("卸载 Codex Health 权限 Hook？其他 Hook 和原有配置会保留。")
  )
    return;
  try {
    message.value = remove
      ? "Hook 已卸载"
      : await props.desktop.command<string>("install_permission_hook");
    if (remove) await props.desktop.command("uninstall_permission_hook");
    await props.desktop.bootstrap();
  } catch (error) {
    message.value = String(error);
  }
}
async function test() {
  try {
    await props.desktop.command("test_permission_notification");
    message.value = "测试提醒已发送";
  } catch (error) {
    message.value = String(error);
  }
}
async function clear() {
  if (!window.confirm("清除本机权限提醒历史？这不会删除 Codex 会话。")) return;
  try {
    await props.desktop.command("mark_permissions", {
      id: null,
      status: "clear",
    });
  } catch (error) {
    message.value = String(error);
  }
}
</script>
<template>
  <Modal title="设置" @close="emit('close')"
    ><div class="segments settings-tabs">
      <button
        v-for="name in ['通用', '提醒', '关于']"
        :key="name"
        :class="{ active: tab === name }"
        @click="tab = name"
      >
        {{ name }}
      </button>
    </div>
    <template v-if="tab === '通用'"
      ><h3>本地数据</h3>
      <div class="settings-group">
        <label>Codex 数据目录</label>
        <p class="path selectable">
          {{ desktop.state.preferences.directory ?? "尚未选择" }}
        </p>
        <small>{{
          desktop.state.snapshot?.accountStatus ?? "选择目录后检查登录状态"
        }}</small
        ><button @click="desktop.choose" :disabled="desktop.state.busy">
          <FolderOpen :size="15" />重新选择 Codex 数据目录…
        </button>
        <p class="muted">
          Token
          按所选目录统计，不区分账户。额度按当前登录隔离；账户变化后等待新采样。不会上传会话正文。
        </p>
      </div>
      <h3>刷新</h3>
      <div class="settings-group">
        <div class="setting-line">
          <label>自动刷新</label
          ><select
            v-model.number="draft.refreshInterval"
            @change="save"
            aria-label="自动刷新"
          >
            <option :value="300">每 5 分钟</option>
            <option :value="900">每 15 分钟</option>
            <option :value="1800">每 30 分钟</option>
          </select>
        </div>
        <p class="muted">
          前台按所选间隔刷新；后台至少 15 分钟，省电模式或低电量时至少 30
          分钟。隐藏窗口停止界面计时，主窗口和悬浮窗口共享刷新结果。
        </p>
      </div>
      <h3>外观</h3>
      <div class="settings-group">
        <label>显示模式</label>
        <div class="segments">
          <button
            v-for="mode in [
              ['system', '跟随系统'],
              ['light', '白天模式'],
              ['dark', '暗黑模式'],
            ]"
            :key="mode[0]"
            :class="{ active: draft.appearance === mode[0] }"
            @click="set('appearance', mode[0] as Preferences['appearance'])"
          >
            {{ mode[1] }}
          </button>
        </div>
        <div class="setting-line">
          <img :src="logo" class="logo-preview" alt="应用 Logo" /><label
            >应用 Logo</label
          ><select
            v-model="draft.iconStyle"
            @change="save"
            aria-label="应用 Logo"
          >
            <option value="flat">扁平 · 黑白（默认）</option>
            <option value="glass">玻璃 · 黑白</option>
          </select>
        </div>
        <small
          >浅色白底黑字，深色黑底白字；应用内
          Logo、任务栏与托盘同步切换。</small
        >
      </div>
      <h3>悬浮窗口</h3>
      <div class="settings-group">
        <label class="check-row"
          ><input
            type="checkbox"
            v-model="draft.floatingEnabled"
            @change="save"
          />显示悬浮窗口</label
        >
        <div class="setting-line">
          <label>样式</label
          ><select
            v-model="draft.floatingStyle"
            @change="save"
            aria-label="悬浮窗口样式"
          >
            <option value="ball">额度悬浮球</option>
            <option value="summary">用量摘要</option>
          </select>
        </div>
        <small
          >拖动调整位置，双击打开健康报告；关闭主窗口后仍可查看摘要。</small
        >
      </div></template
    ><template v-else-if="tab === '提醒'"
      ><h3>低额度提醒</h3>
      <div class="settings-group">
        <label class="check-row"
          ><input
            type="checkbox"
            v-model="draft.quotaNotifications"
            @change="save"
          />额度与预测风险通知</label
        >
        <div class="setting-line">
          <label>提醒阈值</label
          ><select v-model.number="draft.lowRateThreshold" @change="save">
            <option v-for="n in [5, 10, 20, 30, 50]" :key="n" :value="n">
              剩余 {{ n }}% 以下
            </option>
          </select>
        </div>
        <label class="check-row"
          ><input
            type="checkbox"
            v-model="draft.deduplicateAlerts"
            @change="save"
          />同日提醒去重</label
        >
      </div>
      <h3>Codex 权限提醒</h3>
      <div class="settings-group">
        <label class="check-row"
          ><input
            type="checkbox"
            v-model="draft.permissionEnabled"
            @change="save"
          />开启权限提醒</label
        ><small>Hook 状态：{{ desktop.state.hookStatus }}</small
        ><label class="check-row"
          ><input
            type="checkbox"
            v-model="draft.systemNotifications"
            @change="save"
          />Windows 系统通知</label
        ><label class="check-row"
          ><input
            type="checkbox"
            v-model="draft.badgeEnabled"
            @change="save"
          />托盘需要关注数量</label
        ><label class="check-row"
          ><input
            type="checkbox"
            v-model="draft.soundEnabled"
            @change="save"
          />提示音</label
        ><label class="check-row"
          ><input
            type="checkbox"
            v-model="draft.showPreview"
            @change="save"
          />在通知中显示项目和操作类型</label
        >
        <div class="setting-line">
          <label>最近记录保留</label
          ><select v-model.number="draft.retentionHours" @change="save">
            <option :value="1">1 小时</option>
            <option :value="24">24 小时</option>
            <option :value="72">3 天</option>
            <option :value="0">不保存</option>
          </select>
        </div>
        <p class="muted">
          PermissionRequest 可能由 Auto Review
          继续处理，本应用不会自动允许或拒绝。安装后需在 Codex /hooks
          中检查并信任。
        </p>
        <div class="actions wrap">
          <button @click="hook()">安装或修复 Hook</button
          ><button @click="test">发送测试提醒</button
          ><button @click="hook(true)">卸载 Hook</button
          ><button @click="clear">清除提醒历史</button>
        </div>
      </div>
    </template>
    <div v-else class="about">
      <img :src="logo" width="64" height="64" alt="Codex Health" />
      <h2>Codex Health</h2>
      <p>Windows · v0.1.2</p>
      <small>本地优先的 Codex 用量健康中心</small>
    </div>
    <p v-if="message" class="notice" role="status">{{ message }}</p>
    <p v-if="pending" class="muted" role="status">正在保存设置…</p></Modal
  >
</template>
