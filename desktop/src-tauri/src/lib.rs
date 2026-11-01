mod commands;
mod qemu;
mod vm;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(commands::Manager::default())
        .invoke_handler(tauri::generate_handler![
            commands::host_info,
            commands::list_vms,
            commands::create_vm,
            commands::update_vm,
            commands::delete_vm,
            commands::start_vm,
            commands::stop_vm,
            commands::pause_vm,
            commands::resume_vm,
            commands::reset_vm,
            commands::list_snapshots,
            commands::create_snapshot,
            commands::restore_snapshot,
            commands::delete_snapshot,
            commands::open_vm_folder,
        ])
        .run(tauri::generate_context!())
        .expect("erro ao iniciar o VM Guave");
}
