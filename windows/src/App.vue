<script setup lang="ts">
import FloatingBall from "./components/FloatingBall.vue";
import Dashboard from "./components/Dashboard.vue";
const floating =
  new URLSearchParams(location.search).get("window") === "floating";
</script>
<template><FloatingBall v-if="floating" /><Dashboard v-else /></template>
