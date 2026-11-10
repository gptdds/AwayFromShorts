// ============================================================
//  AwayFromShorts - Tauri thin shell
//  只做两件事: 提供原生窗口(加载 http://127.0.0.1:8737) + 系统托盘
//  不动任何 PowerShell 代码, 不替换 webui.ps1, 只是额外一层壳
// ============================================================

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager, WindowEvent,
};

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

/// 检测 webui.ps1 是否已在监听 8737 端口
fn is_panel_running() -> bool {
    use std::net::TcpStream;
    use std::time::Duration;
    TcpStream::connect_timeout(
        &"127.0.0.1:8737".parse().unwrap(),
        Duration::from_millis(1500),
    )
    .is_ok()
}

/// 尝试启动 webui.ps1 (复用 start-web.bat 的逻辑)
/// 优先触发计划任务; 若计划任务不存在, 直接启动 webui.ps1
fn ensure_panel_running() {
    if is_panel_running() {
        return;
    }

    // 尝试通过计划任务启动 (不弹 UAC)
    let mut task_cmd = std::process::Command::new("schtasks");
    task_cmd.args(["/Run", "/TN", "AwayFromShorts-WebUI"]);
    #[cfg(windows)]
    {
        task_cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let task_result = task_cmd.output();

    // 如果计划任务不存在或失败, 尝试直接从安装目录启动
    if task_result.is_err() || !task_result.unwrap().status.success() {
        let local_app = std::env::var("LOCALAPPDATA").unwrap_or_default();
        let webui_path = format!("{}\\AwayFromShorts\\src\\webui.ps1", local_app);

        if std::path::Path::new(&webui_path).exists() {
            let mut pwsh_cmd = std::process::Command::new("powershell");
            pwsh_cmd.args([
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-WindowStyle",
                "Hidden",
                "-File",
                &webui_path,
            ]);
            #[cfg(windows)]
            {
                pwsh_cmd.creation_flags(CREATE_NO_WINDOW);
            }
            let _ = pwsh_cmd.spawn();
        }
    }

    // 等待面板就绪 (最多 15 秒)
    for _ in 0..30 {
        if is_panel_running() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
}

fn is_autostart() -> bool {
    std::env::args().any(|a| a == "--autostart")
}

#[tauri::command]
fn check_panel() -> bool {
    is_panel_running()
}

#[tauri::command]
fn start_panel() -> bool {
    ensure_panel_running();
    is_panel_running()
}

fn main() {
    // 启动前先确保面板在跑
    ensure_panel_running();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![check_panel, start_panel])
        .setup(|app| {
            // --autostart: launched by the AtLogOn scheduled task. Stay in the
            // tray only, do not steal focus at login.
            if is_autostart() {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }
            let show_item = MenuItem::with_id(app, "show", "显示面板", true, None::<&str>)?;
            let hide_item = MenuItem::with_id(app, "hide", "隐藏到托盘", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;

            let menu = Menu::with_items(app, &[&show_item, &hide_item, &quit_item])?;

            let _tray = TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("AwayFromShorts")
                .menu(&menu)
                .on_tray_icon_event(|tray, event| {
                    // 左键单击: 切换窗口显示/隐藏
                    if let tauri::tray::TrayIconEvent::Click {
                        button: tauri::tray::MouseButton::Left,
                        button_state: tauri::tray::MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            if window.is_visible().unwrap_or(false) {
                                let _ = window.hide();
                            } else {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                    }
                })
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "hide" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.hide();
                        }
                    }
                    "quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app)?;

            Ok(())
        })
        .on_window_event(|window, event| {
            // 关闭按钮 → 最小化到托盘而不是退出 (仅 release 模式)
            if let WindowEvent::CloseRequested { api, .. } = event {
                #[cfg(not(debug_assertions))]
                {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
