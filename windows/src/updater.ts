import { reactive } from 'vue';
import { Channel } from '@tauri-apps/api/core';

export interface UpdateMetadata { version: string; notes: string | null }
interface UpdateCheck { currentVersion: string; update: UpdateMetadata | null }
interface DownloadProgress { phase: 'downloading' | 'installing'; downloaded: number; total: number | null }
type Command = <T>(name: string, args?: Record<string, unknown>) => Promise<T>;

export function useAppUpdater(command: Command) {
  const state = reactive({ version: '', checking: false, installing: false, update: null as UpdateMetadata | null, message: '', error: '', downloaded: 0, total: null as number | null });
  async function loadVersion() {
    try { state.version = await command<string>('app_version'); } catch { /* Browser preview has no native app version. */ }
  }
  async function checkUpdate() {
    if (state.checking || state.installing) return;
    state.checking = true;
    state.error = '';
    state.message = '';
    state.update = null;
    try {
      const result = await command<UpdateCheck>('check_app_update');
      state.version = result.currentVersion;
      state.update = result.update;
      state.message = result.update ? `发现新版本 v${result.update.version}` : '当前已是最新版本';
    } catch (error) { state.error = String(error); }
    finally { state.checking = false; }
  }
  async function installUpdate() {
    if (!state.update || state.checking || state.installing) return;
    state.installing = true;
    state.error = '';
    state.downloaded = 0;
    state.total = null;
    state.message = '正在下载并验证更新…';
    try {
      const onEvent = new Channel<DownloadProgress>();
      onEvent.onmessage = (event) => {
        state.downloaded = event.downloaded;
        state.total = event.total;
        state.message = event.phase === 'installing' ? '正在验证更新并启动安装程序…' : '正在下载更新…';
      };
      await command('install_app_update', { version: state.update.version, onEvent });
      state.message = '安装程序已启动';
    } catch (error) {
      state.error = String(error);
      state.update = null;
      state.message = '';
    } finally { state.installing = false; }
  }
  return { state, loadVersion, checkUpdate, installUpdate };
}
