<script setup lang="ts">
import { computed } from "vue";
import { tokens } from "../types";
const props = defineProps<{
  days: { date: string; tokens: number }[];
  hourly?: boolean;
}>();
const peak = computed(() => Math.max(1, ...props.days.map((d) => d.tokens)));
</script>
<template>
  <div class="chart" :class="{ hourly }">
    <div
      v-for="day in days"
      :key="day.date"
      class="bar-column"
      :title="`${day.date}：${day.tokens.toLocaleString()} Token`"
    >
      <span>{{ tokens(day.tokens) }}</span>
      <div class="bar-space">
        <div
          class="bar"
          :style="{ height: `${Math.max(1, (day.tokens / peak) * 100)}%` }"
        ></div>
      </div>
      <span>{{
        hourly
          ? new Date(day.date).toLocaleTimeString("zh-CN", {
              hour: "2-digit",
              hour12: false,
            })
          : day.date.slice(5).replace("-", "/")
      }}</span>
    </div>
  </div>
</template>
