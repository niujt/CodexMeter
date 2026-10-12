<script setup lang="ts">
import { computed } from "vue";
import { Bell, Check, Terminal, ShieldCheck } from "@lucide/vue";
import type { DesktopClient } from "../desktop";
import { projectName } from "../types";
const props = defineProps<{ desktop: DesktopClient }>();
const state = props.desktop.state;
const unread = computed(
  () =>
    state.permissions.filter(
      (e) => e.status === "new" && e.attention !== "info",
    ).length,
);
async function mark(id: string | null, status: string) {
  try {
    await props.desktop.command("mark_permissions", { id, status });
  } catch (error) {
    props.desktop.fail(error);
  }
}
async function open() {
  try {
    await props.desktop.command("open_codex");
  } catch (error) {
    props.desktop.fail(error);
  }
}
</script>
<template>
  <section class="flat">
    <div class="section-heading">
      <h2><Bell :size="15" />权限请求 · 需要关注 {{ unread }}</h2>
      <div class="actions">
        <button @click="open"><Terminal :size="14" />打开 Codex</button
        ><button @click="mark(null, 'seen')" :disabled="!unread">
          <Check :size="14" />全部已读
        </button>
      </div>
    </div>
    <p v-if="!state.permissions.length" class="muted">
      暂无权限请求记录。PermissionRequest 可能由 Auto Review
      继续处理，本应用不会自动允许或拒绝。
    </p>
    <div
      v-for="event in state.permissions.slice(0, 10)"
      :key="event.eventId"
      class="permission-row"
    >
      <ShieldCheck :size="17" />
      <div>
        <strong class="small-title"
          >{{ projectName(event.project) }} · {{ event.toolName }}</strong
        ><small
          >{{
            event.attention === "human"
              ? "明确需要人工关注"
              : event.attention === "info"
                ? "自动审查信息"
                : "可能需要关注"
          }}
          · {{ new Date(event.receivedAt).toLocaleString() }} ·
          {{
            event.status === "new"
              ? "未读"
              : event.status === "seen"
                ? "已读"
                : event.status === "expired"
                  ? "已过期"
                  : "已忽略"
          }}</small
        >
      </div>
      <button
        v-if="event.status === 'new'"
        @click="mark(event.eventId, 'seen')"
      >
        已读
      </button>
    </div>
  </section>
</template>
