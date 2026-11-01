//! Comandos chamados pela interface (invoke). O estado de cada VM vem do próprio QEMU,
//! via QMP na porta gravada em run.json — assim uma VM continua controlável mesmo se o app
//! for fechado e aberto de novo com ela ligada.
use crate::qemu::{self, Host};
use crate::vm::{self, GuestOs, PortForward, VmConfig, VmPaths};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    process::{Child, Command, Stdio},
    sync::Mutex,
    thread,
    time::Duration,
};
use tauri::State;

type CmdResult<T> = Result<T, String>;

#[derive(Default)]
pub struct Manager {
    /// Processos iniciados por esta sessão (para colher o código de saída).
    children: Mutex<HashMap<String, Child>>,
    /// O QMP atende um cliente por vez; serializa as conexões.
    qmp_lock: Mutex<()>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RunState {
    qmp_port: u16,
    pid: u32,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RunStatus {
    Stopped,
    Starting,
    Running,
    Paused,
}

impl Manager {
    fn reap(&self) {
        let mut children = self.children.lock().unwrap();
        children.retain(|id, child| {
            let exited = !matches!(child.try_wait(), Ok(None));
            if exited {
                if let Ok(paths) = VmPaths::new(id) {
                    let _ = fs::remove_file(paths.run_state());
                }
            }
            !exited
        });
    }

    fn qmp(&self, id: &str, command: &str) -> CmdResult<serde_json::Value> {
        let port = run_state(id).ok_or("A VM não está ligada.")?.qmp_port;
        let _guard = self.qmp_lock.lock().unwrap();
        qemu::qmp(port, command)
    }

    fn status(&self, id: &str) -> RunStatus {
        let Some(state) = run_state(id) else { return RunStatus::Stopped };
        let reply = {
            let _guard = self.qmp_lock.lock().unwrap();
            qemu::qmp(state.qmp_port, "query-status")
        };
        match reply {
            Ok(v) if v["return"]["status"] == "paused" => RunStatus::Paused,
            Ok(_) => RunStatus::Running,
            // Acabou de ligar e o QMP ainda não abriu a porta.
            Err(_) if self.children.lock().unwrap().contains_key(id) => RunStatus::Starting,
            Err(_) => {
                // Sobra de uma sessão que terminou sem limpar.
                if let Ok(paths) = VmPaths::new(id) {
                    let _ = fs::remove_file(paths.run_state());
                }
                RunStatus::Stopped
            }
        }
    }

    fn require_stopped(&self, id: &str) -> CmdResult<()> {
        self.reap();
        if self.status(id) == RunStatus::Stopped {
            Ok(())
        } else {
            Err("Desligue a VM antes.".into())
        }
    }
}

fn run_state(id: &str) -> Option<RunState> {
    let paths = VmPaths::new(id).ok()?;
    serde_json::from_slice(&fs::read(paths.run_state()).ok()?).ok()
}

fn log_tail(paths: &VmPaths) -> String {
    let log = fs::read_to_string(paths.log()).unwrap_or_default();
    let lines: Vec<&str> = log.lines().filter(|l| !l.trim().is_empty()).collect();
    lines[lines.len().saturating_sub(8)..].join("\n")
}

// MARK: Host

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostInfo {
    os: &'static str,
    arch: &'static str,
    qemu: Option<String>,
    accel: &'static str,
    hardware_accel: bool,
    uefi: bool,
    library_dir: String,
    warnings: Vec<String>,
}

#[tauri::command]
pub async fn host_info() -> CmdResult<HostInfo> {
    let host = Host::detect()?;
    let mut warnings = Vec::new();
    if host.qemu.is_none() || host.qemu_img.is_none() {
        warnings.push(qemu::missing_qemu_message());
    }
    if cfg!(target_os = "linux") && !host.accel.is_hardware() {
        warnings.push(if std::path::Path::new("/dev/kvm").exists() {
            "Sem permissão no /dev/kvm: rode 'sudo usermod -aG kvm $USER' e entre de novo na sessão. Até lá as VMs ficam muito lentas.".into()
        } else {
            "KVM indisponível: ative a virtualização (VT-x/AMD-V) na BIOS. Até lá as VMs ficam muito lentas.".into()
        });
    }
    if cfg!(target_os = "windows") {
        warnings.push("Para as VMs rodarem rápido, ative \"Plataforma do Hipervisor do Windows\" em Recursos do Windows e reinicie o PC.".into());
    }
    if host.qemu.is_some() && host.firmware.is_none() {
        warnings.push("Firmware UEFI (OVMF) não encontrado: as VMs vão usar BIOS legado, que o Windows 11 não aceita.".into());
    }
    Ok(HostInfo {
        os: std::env::consts::OS,
        arch: std::env::consts::ARCH,
        qemu: host.qemu.as_ref().map(|p| p.display().to_string()),
        accel: host.accel.label(),
        hardware_accel: host.accel.is_hardware(),
        uefi: host.firmware.is_some(),
        library_dir: vm::library_dir().display().to_string(),
        warnings,
    })
}

// MARK: Biblioteca

#[derive(Serialize)]
pub struct VmView {
    #[serde(flatten)]
    config: VmConfig,
    state: RunStatus,
}

#[tauri::command]
pub async fn list_vms(manager: State<'_, Manager>) -> CmdResult<Vec<VmView>> {
    manager.reap();
    Ok(vm::load_all()
        .into_iter()
        .map(|config| {
            let state = manager.status(&config.id);
            VmView { config, state }
        })
        .collect())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewVm {
    name: String,
    os: GuestOs,
    cpus: u32,
    memory_gb: u32,
    disk_gb: u32,
    iso: Option<String>,
}

fn validate(name: &str, cpus: u32, memory_gb: u32, disk_gb: u32) -> CmdResult<()> {
    let max_cpus = thread::available_parallelism().map(|n| n.get() as u32).unwrap_or(4);
    if name.trim().is_empty() {
        return Err("Dê um nome à VM.".into());
    }
    if cpus == 0 || cpus > max_cpus {
        return Err(format!("CPUs deve ficar entre 1 e {max_cpus}."));
    }
    if memory_gb == 0 || memory_gb > 512 {
        return Err("Memória inválida.".into());
    }
    if !(8..=4096).contains(&disk_gb) {
        return Err("O disco deve ter entre 8 e 4096 GB.".into());
    }
    Ok(())
}

#[tauri::command]
pub async fn create_vm(request: NewVm) -> CmdResult<VmConfig> {
    validate(&request.name, request.cpus, request.memory_gb, request.disk_gb)?;
    let host = Host::detect()?;
    let img = host.qemu_img()?;
    let id = uuid::Uuid::new_v4();
    let config = VmConfig {
        id: id.to_string(),
        name: request.name.trim().to_string(),
        os: request.os,
        cpus: request.cpus,
        memory_gb: request.memory_gb,
        disk_gb: request.disk_gb,
        iso: request.iso.filter(|s| !s.is_empty()),
        mac: vm::mac_for(&id),
        uefi: true,
        port_forwards: Vec::new(),
        created_at: vm::now(),
    };
    let paths = VmPaths::new(&config.id)?;
    fs::create_dir_all(&paths.dir).map_err(|e| e.to_string())?;
    let result = qemu::create_disk(img, &paths.disk(), config.disk_gb).and_then(|_| vm::save(&config));
    if let Err(error) = result {
        let _ = fs::remove_dir_all(&paths.dir);
        return Err(format!("Não foi possível criar a VM: {error}"));
    }
    Ok(config)
}

#[tauri::command]
pub async fn update_vm(manager: State<'_, Manager>, config: VmConfig) -> CmdResult<VmConfig> {
    let current = vm::load(&config.id)?;
    validate(&config.name, config.cpus, config.memory_gb, config.disk_gb)?;
    manager.require_stopped(&config.id)?;
    if config.disk_gb < current.disk_gb {
        return Err("O disco não pode diminuir.".into());
    }
    let mut seen = std::collections::HashSet::new();
    for PortForward { host, guest } in &config.port_forwards {
        if *host < 1024 || *guest == 0 {
            return Err("Portas do computador abaixo de 1024 exigem administrador; use 1024 ou mais.".into());
        }
        if !seen.insert(*host) {
            return Err(format!("A porta {host} aparece duas vezes."));
        }
    }
    if config.disk_gb > current.disk_gb {
        let host = Host::detect()?;
        qemu::resize_disk(host.qemu_img()?, &VmPaths::new(&config.id)?.disk(), config.disk_gb)?;
    }
    // Id, MAC e data de criação não mudam por aqui.
    let updated = VmConfig { id: current.id, mac: current.mac, created_at: current.created_at, ..config };
    vm::save(&updated)?;
    Ok(updated)
}

#[tauri::command]
pub async fn delete_vm(manager: State<'_, Manager>, id: String) -> CmdResult<()> {
    manager.require_stopped(&id)?;
    let paths = VmPaths::new(&id)?;
    fs::remove_dir_all(&paths.dir).map_err(|e| format!("Não foi possível excluir: {e}"))
}

#[tauri::command]
pub async fn open_vm_folder(id: String) -> CmdResult<()> {
    let paths = VmPaths::new(&id)?;
    tauri_plugin_opener::open_path(&paths.dir, None::<&str>).map_err(|e| e.to_string())
}

// MARK: Energia

#[tauri::command]
pub async fn start_vm(manager: State<'_, Manager>, id: String) -> CmdResult<()> {
    let config = vm::load(&id)?;
    manager.require_stopped(&id)?;
    let host = Host::detect()?;
    let qemu_path = host.qemu()?.to_path_buf();
    let paths = VmPaths::new(&id)?;
    if qemu::uses_uefi(&config, &host) {
        qemu::prepare_efi_vars(host.firmware.as_ref().unwrap(), &paths)?;
    }
    let port = qemu::free_port()?;
    let args = qemu::build_args(&config, &paths, &host, port)?;

    let log = fs::File::create(paths.log()).map_err(|e| e.to_string())?;
    let mut cmd = Command::new(&qemu_path);
    cmd.args(&args)
        .current_dir(&paths.dir)
        .stdin(Stdio::null())
        .stdout(log.try_clone().map_err(|e| e.to_string())?)
        .stderr(log);
    qemu::no_console(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("Não foi possível iniciar o QEMU: {e}"))?;

    // Erros de configuração (ISO, firmware, aceleração) derrubam o QEMU logo no início.
    thread::sleep(Duration::from_millis(1500));
    if let Ok(Some(status)) = child.try_wait() {
        let detail = log_tail(&paths);
        return Err(format!("O QEMU encerrou ({status}).\n{detail}"));
    }
    let state = RunState { qmp_port: port, pid: child.id() };
    fs::write(paths.run_state(), serde_json::to_vec(&state).unwrap()).map_err(|e| e.to_string())?;
    manager.children.lock().unwrap().insert(id, child);
    Ok(())
}

#[tauri::command]
pub async fn stop_vm(manager: State<'_, Manager>, id: String, force: bool) -> CmdResult<()> {
    if force {
        // "quit" encerra na hora, como tirar da tomada.
        if manager.qmp(&id, "quit").is_err() {
            if let Some(child) = manager.children.lock().unwrap().get_mut(&id) {
                let _ = child.kill();
            }
        }
        thread::sleep(Duration::from_millis(500));
        manager.reap();
        Ok(())
    } else {
        // Botão de energia ACPI: o sistema convidado desliga sozinho.
        manager.qmp(&id, "system_powerdown").map(|_| ())
    }
}

#[tauri::command]
pub async fn pause_vm(manager: State<'_, Manager>, id: String) -> CmdResult<()> {
    manager.qmp(&id, "stop").map(|_| ())
}

#[tauri::command]
pub async fn resume_vm(manager: State<'_, Manager>, id: String) -> CmdResult<()> {
    manager.qmp(&id, "cont").map(|_| ())
}

#[tauri::command]
pub async fn reset_vm(manager: State<'_, Manager>, id: String) -> CmdResult<()> {
    manager.qmp(&id, "system_reset").map(|_| ())
}

// MARK: Snapshots (internos do qcow2, com a VM desligada)

#[tauri::command]
pub async fn list_snapshots(id: String) -> CmdResult<Vec<qemu::Snapshot>> {
    let host = Host::detect()?;
    qemu::list_snapshots(host.qemu_img()?, &VmPaths::new(&id)?.disk())
}

fn snapshot_op(manager: &Manager, id: &str, flag: &str, name: &str) -> CmdResult<()> {
    if name.trim().is_empty() {
        return Err("Dê um nome ao snapshot.".into());
    }
    manager.require_stopped(id)?;
    let host = Host::detect()?;
    qemu::snapshot(host.qemu_img()?, &VmPaths::new(id)?.disk(), flag, name.trim())
}

#[tauri::command]
pub async fn create_snapshot(manager: State<'_, Manager>, id: String, name: String) -> CmdResult<()> {
    let host = Host::detect()?;
    let existing = qemu::list_snapshots(host.qemu_img()?, &VmPaths::new(&id)?.disk())?;
    if existing.iter().any(|s| s.name == name.trim()) {
        return Err(format!("Já existe um snapshot chamado \"{}\".", name.trim()));
    }
    snapshot_op(&manager, &id, "-c", &name)
}

#[tauri::command]
pub async fn restore_snapshot(manager: State<'_, Manager>, id: String, name: String) -> CmdResult<()> {
    snapshot_op(&manager, &id, "-a", &name)
}

#[tauri::command]
pub async fn delete_snapshot(manager: State<'_, Manager>, id: String, name: String) -> CmdResult<()> {
    snapshot_op(&manager, &id, "-d", &name)
}
