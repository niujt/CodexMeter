<script setup lang="ts">
import { ref, watch, computed } from "vue";
import type { ApiAccounts, ApiProvider } from "../apiAccounts";
const props = defineProps<{accounts: ApiAccounts; initialProvider?: ApiProvider}>();
const emit = defineEmits<{saved: [provider: ApiProvider]}>();
const provider = ref<ApiProvider>(props.initialProvider ?? "openai");
const keyText = ref("");
const saving = ref(false);
const feedback = ref("");
const state = computed(() => props.accounts.states[provider.value]);
watch(provider, (value) => { keyText.value = ""; feedback.value = ""; void props.accounts.status(value); }, {immediate: true});
async function save(text = keyText.value) {
  if (saving.value) return;
  const selected = provider.value;
  saving.value = true;
  try {
    if (await props.accounts.save(selected, text)) {
      keyText.value = "";
      feedback.value = "密钥已保存到 Windows 凭据管理器。";
      emit("saved", selected);
    } else { feedback.value = ""; }
  } finally { saving.value = false; }
}
async function importKey(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  if (!file) return;
  try {
    if (file.size > 16_384) { feedback.value = "请选择只含一个 API Key 的小型文本文件。"; return; }
    const selected = provider.value;
    const text = await file.text();
    if (provider.value === selected) await save(text);
  } catch { feedback.value = "无法读取密钥文件，请选择 UTF-8 文本。"; }
  finally { input.value = ""; }
}
</script>
<template>
  <div class="setting-line"><label for="api-provider">服务商</label><select id="api-provider" v-model="provider" :disabled="saving"><option value="openai">OpenAI</option><option value="deepseek">DeepSeek</option></select></div>
  <h3>{{ provider === 'openai' ? 'OpenAI 官方 API' : 'DeepSeek 官方 API' }}</h3>
  <div class="settings-group">
    <p class="muted">{{ provider === 'openai' ? 'https://api.openai.com/v1' : 'https://api.deepseek.com' }}</p>
    <p>{{ state.configured ? '密钥已独立保存到 Windows 凭据管理器' : '尚未配置密钥' }}</p>
    <label for="api-key">{{ provider === 'openai' ? 'Admin API Key' : 'DeepSeek API Key' }}</label>
    <input id="api-key" type="password" v-model="keyText" autocomplete="off" spellcheck="false" maxlength="2048" :disabled="saving" placeholder="输入对应服务商的新密钥以保存或替换" />
    <div class="actions wrap">
      <button @click="save()" :disabled="!keyText.trim() || saving">保存到凭据管理器</button>
      <label class="file-import">从文件导入…<input type="file" accept=".txt,text/plain" @change="importKey" :disabled="saving" /></label>
    </div>
    <small>点击保存或导入，将把密钥独立保存到此电脑的 Windows 凭据管理器。只向对应官方接口发送只读查询，不调用模型。</small>
    <p v-if="feedback" role="status">{{ feedback }}</p>
    <p v-if="state.error" class="notice" role="alert">{{ state.error }}</p>
  </div>
  <h3>查询范围</h3>
  <div class="settings-group">
    <p v-if="provider === 'openai'">组织费用与用量需要 api.usage.read；月度消费上限需要 api.management.read。请使用 Admin API Key。充值余额以官方账单页为准。</p>
    <p v-else>普通 DeepSeek API Key 可查询总可用余额、充值余额和未过期赠金。人民币与美元分别展示。</p>
    <small>进入对应页面时查询，5 分钟内复用内存结果；手动刷新立即查询。密钥不会写入偏好、统计缓存或安装包。</small>
    <button @click="accounts.openConsole(provider)">打开官方控制台</button>
  </div>
</template>
