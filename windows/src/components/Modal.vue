<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { X } from "@lucide/vue";
const props = defineProps<{ title: string; wide?: boolean }>();
const emit = defineEmits<{ close: [] }>();
const element = ref<HTMLElement>();
let previous: Element | null = null;
function key(event: KeyboardEvent) {
  if (event.key === "Escape") {
    event.stopPropagation();
    emit("close");
  }
  if (event.key === "Tab") {
    const nodes = element.value?.querySelectorAll<HTMLElement>(
      'button:not(:disabled),input,select,a[href],[tabindex="0"]',
    );
    if (!nodes?.length) return;
    const first = nodes[0]!,
      last = nodes[nodes.length - 1]!;
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }
}
onMounted(() => {
  previous = document.activeElement;
  element.value?.focus();
});
onUnmounted(() => {
  if (previous instanceof HTMLElement) previous.focus();
});
</script>
<template>
  <div class="modal-backdrop" @click.self="emit('close')">
    <section
      ref="element"
      class="modal"
      :class="{ wide }"
      role="dialog"
      aria-modal="true"
      :aria-label="props.title"
      tabindex="-1"
      @keydown="key"
    >
      <div class="section-heading">
        <h2>{{ title }}</h2>
        <button @click="emit('close')" :aria-label="`关闭${title}`">
          <X :size="18" />
        </button>
      </div>
      <slot />
    </section>
  </div>
</template>
