use serde::Serialize;
use tauri::{ipc::Channel, AppHandle};
use tauri_plugin_updater::UpdaterExt;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateMetadata {
    version: String,
    notes: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCheck {
    current_version: String,
    update: Option<UpdateMetadata>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgress {
    phase: &'static str,
    downloaded: u64,
    total: Option<u64>,
}

#[tauri::command]
pub fn app_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[tauri::command]
pub async fn check_app_update(app: AppHandle) -> Result<UpdateCheck, String> {
    let update = app
        .updater_builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|e| format!("无法准备更新检查：{e}"))?
        .check()
        .await
        .map_err(|e| format!("检查更新失败，请检查网络后重试：{e}"))?;
    Ok(UpdateCheck {
        current_version: app_version().into(),
        update: update.map(|u| UpdateMetadata {
            version: u.version,
            notes: u.body,
        }),
    })
}

#[tauri::command]
pub async fn install_app_update(
    app: AppHandle,
    version: String,
    on_event: Channel<DownloadProgress>,
) -> Result<(), String> {
    if !cfg!(windows) {
        return Err("此更新安装入口仅用于 Windows 版".into());
    }
    // Recheck at installation time; the webview cannot choose an arbitrary URL or version.
    let update = app
        .updater_builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .map_err(|e| format!("无法准备更新：{e}"))?
        .check()
        .await
        .map_err(|e| format!("无法获取更新，请重新检查：{e}"))?
        .ok_or("当前已是最新版本，请重新检查")?;
    if update.version != version {
        return Err("发布版本已变化，请重新检查更新后安装".into());
    }
    let mut downloaded = 0;
    let finished = on_event.clone();
    update
        .download_and_install(
            move |chunk, total| {
                downloaded += chunk as u64;
                let _ = on_event.send(DownloadProgress {
                    phase: "downloading",
                    downloaded,
                    total,
                });
            },
            move || {
                let _ = finished.send(DownloadProgress {
                    phase: "installing",
                    downloaded: 0,
                    total: None,
                });
            },
        )
        .await
        .map_err(|e| format!("更新失败（下载或签名校验），请重新检查后重试：{e}"))
}
