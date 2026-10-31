<script setup lang="ts">
import { computed, onMounted } from "vue";
import { money, count, type ApiAccounts, type ApiProvider } from "../apiAccounts";
const props = defineProps<{provider: ApiProvider; accounts: ApiAccounts}>();
const emit = defineEmits<{settings: [provider: ApiProvider]}>();
const state = computed(() => props.accounts.states[props.provider]);
const snapshot = computed(() => state.value.snapshot);
const costText = computed(() => {
  const costs = snapshot.value?.costs;
  if (costs == null) return "—";
  return Object.keys(costs).length ? Object.entries(costs).map(([c,v]) => money(v,c)).join(" / ") : money("0");
});
onMounted(() => { void props.accounts.load(props.provider); });
</script>
<template>
  <div class="api-toolbar actions"><button @click="emit('settings', provider)">设置密钥</button><button @click="accounts.load(provider, true)" :disabled="state.busy">{{ state.busy ? '正在查询…' : '刷新 API' }}</button></div>
  <div v-if="state.error" class="notice" role="alert">{{ state.error }}<p v-if="snapshot">以下为上次成功查询的结果，请留意查询时间。</p></div>
  <div v-if="!state.configured && !state.busy" class="empty"><h2>连接 {{ provider === 'openai' ? 'OpenAI API' : 'DeepSeek' }}</h2><p>在设置 → API 配置对应服务商的密钥。</p><button @click="emit('settings', provider)">配置密钥</button></div>
  <template v-if="snapshot && provider === 'deepseek'">
    <p class="muted">{{ state.error ? '上次查询：' : '' }}{{ snapshot.isAvailable ? '余额可供 API 调用' : '无可用余额供 API 调用' }}</p>
    <section v-for="item in snapshot.balances ?? []" :key="item.currency" class="api-currency">
      <h3>{{ item.currency === 'CNY' ? '人民币 · CNY' : '美元 · USD' }}</h3>
      <div class="metrics api-metrics">
        <div><label>剩余可用余额</label><strong>{{ money(item.total, item.currency) }}</strong><small>充值余额 + 未过期赠金</small></div>
        <div><label>充值余额</label><strong>{{ money(item.toppedUp, item.currency) }}</strong><small>当前账户剩余充值金额</small></div>
        <div><label>未过期赠金</label><strong>{{ money(item.granted, item.currency) }}</strong><small>当前仍可使用的赠金</small></div>
      </div>
    </section>
    <p v-if="!snapshot.balances?.length" class="notice">官方接口未返回余额明细，请到官方控制台核对。</p>
  </template>
  <template v-if="snapshot && provider === 'openai'">
    <div class="metrics api-metrics">
      <div><label>本月消费</label><strong>{{ costText }}</strong><small>组织全部 API 费用</small></div>
      <div><label>月度消费上限</label><strong>{{ snapshot.limit ? (snapshot.limit.configured ? money(snapshot.limit.amount) : '未配置') : '—' }}</strong><small>{{ snapshot.limit?.configured ? (snapshot.limit.enforcing ? '已启用硬限制' : '硬限制未生效') : '组织月度消费上限' }}</small></div>
      <div><label>预算剩余估算</label><strong>{{ money(snapshot.budgetRemaining) }}</strong><small>上限减去已记录消费</small></div>
    </div>
    <section><h3>本月文本 API 用量</h3><div class="api-token-grid"><div><label>输入 Token</label><b>{{ count(snapshot.usage?.input) }}</b></div><div><label>其中缓存输入</label><b>{{ count(snapshot.usage?.cachedInput) }}</b></div><div><label>输出 Token</label><b>{{ count(snapshot.usage?.output) }}</b></div><div><label>请求数</label><b>{{ count(snapshot.usage?.requests) }}</b></div></div><p class="muted">缓存输入已包含在输入 Token 中。组织月度数据按 UTC 统计，包含当天已记录费用。</p></section>
    <div v-if="snapshot.warnings.length" class="notice" role="alert"><p v-for="warning in snapshot.warnings" :key="warning">{{ warning }}</p></div>
  </template>
  <p v-if="snapshot" class="muted api-timestamp">查询时间：{{ new Date(snapshot.checkedAt).toLocaleString() }}</p>
  <section><h3>{{ provider === 'openai' ? '统计范围' : '余额说明' }}</h3>
    <p v-if="provider === 'openai'" class="muted">费用涵盖组织全部 API 消费，文本用量不涵盖所有音频、图像和存储用量。预算剩余估算与充值余额分别计算，充值余额请查看官方账单页。</p>
    <p v-else class="muted">余额属于当前密钥对应的 DeepSeek 账户。人民币与美元分别展示，不合并换算。</p>
    <p class="muted">进入页面时按需查询，5 分钟内复用内存结果；手动刷新立即查询。查询不上传 Codex 会话正文。</p><button @click="accounts.openConsole(provider)">打开官方控制台</button>
  </section>
</template>
