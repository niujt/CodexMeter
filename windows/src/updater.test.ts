import { describe, it, expect, vi } from 'vitest';
import { useAppUpdater } from './updater';
vi.mock('@tauri-apps/api/core', () => ({Channel: class { onmessage = (_event: unknown) => {}; }}));

describe('应用更新', () => {
  it('shows current version and never installs without an available update', async () => {
    const command = vi.fn().mockResolvedValue({currentVersion:'0.1.3', update:null});
    const updater = useAppUpdater(command);
    await updater.checkUpdate();
    expect(updater.state.version).toBe('0.1.3');
    expect(updater.state.message).toBe('当前已是最新版本');
    await updater.installUpdate();
    expect(command).toHaveBeenCalledTimes(1);
  });
  it('downloads only after a click and shows progress, with no duplicate install', async () => {
    let finish!: () => void;
    const command = vi.fn().mockResolvedValueOnce({currentVersion:'0.1.3',update:{version:'0.1.4',notes:'更新说明'}})
      .mockImplementationOnce(async (_name, args) => {
        args.onEvent.onmessage({phase:'downloading',downloaded:50,total:100});
        await new Promise<void>(resolve => { finish = resolve; });
      });
    const updater = useAppUpdater(command);
    await updater.checkUpdate();
    expect(command).toHaveBeenCalledTimes(1);
    const installing = updater.installUpdate();
    expect(updater.state.downloaded).toBe(50);
    expect(updater.state.total).toBe(100);
    await updater.installUpdate();
    expect(command).toHaveBeenCalledTimes(2);
    expect(command.mock.calls[1][1].version).toBe('0.1.4');
    finish(); await installing;
  });
  it('clears failed checks and installations so errors cannot be mistaken for up-to-date', async () => {
    const command = vi.fn().mockRejectedValueOnce('network unavailable')
      .mockResolvedValueOnce({currentVersion:'0.1.3',update:{version:'0.1.4',notes:null}})
      .mockRejectedValueOnce('signature verification failed');
    const updater = useAppUpdater(command);
    await updater.checkUpdate();
    expect(updater.state.error).toContain('network unavailable');
    expect(updater.state.message).toBe('');
    await updater.checkUpdate(); await updater.installUpdate();
    expect(updater.state.error).toContain('signature verification failed');
    expect(updater.state.update).toBeNull();
    expect(updater.state.installing).toBe(false);
    expect(updater.state.message).toBe('');
  });
});
