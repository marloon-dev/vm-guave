//! Configuração e arquivos de cada VM. Cada VM é uma pasta <uuid>/ com config.json,
//! disk.qcow2, efi-vars.fd, qemu.log e run.json (enquanto está ligada).
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf, time::SystemTime};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum GuestOs {
    Linux,
    Windows,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PortForward {
    pub host: u16,
    pub guest: u16,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VmConfig {
    pub id: String,
    pub name: String,
    pub os: GuestOs,
    pub cpus: u32,
    pub memory_gb: u32,
    pub disk_gb: u32,
    #[serde(default)]
    pub iso: Option<String>,
    pub mac: String,
    #[serde(default = "default_true")]
    pub uefi: bool,
    #[serde(default)]
    pub port_forwards: Vec<PortForward>,
    #[serde(default)]
    pub created_at: u64,
}

fn default_true() -> bool {
    true
}

/// Pasta das VMs. VMGUAVE_HOME troca a base (usado nos testes).
pub fn library_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("VMGUAVE_HOME") {
        return PathBuf::from(home).join("VMs");
    }
    let base = dirs::data_dir().unwrap_or_else(std::env::temp_dir);
    let name = if cfg!(target_os = "linux") { "vm-guave" } else { "VM Guave" };
    base.join(name).join("VMs")
}

pub struct VmPaths {
    pub dir: PathBuf,
}

impl VmPaths {
    /// O id vem da interface: só aceita UUID para não sair da pasta das VMs.
    pub fn new(id: &str) -> Result<Self, String> {
        uuid::Uuid::parse_str(id).map_err(|_| format!("ID de VM inválido: {id}"))?;
        Ok(Self { dir: library_dir().join(id) })
    }
    pub fn config(&self) -> PathBuf {
        self.dir.join("config.json")
    }
    pub fn disk(&self) -> PathBuf {
        self.dir.join("disk.qcow2")
    }
    pub fn efi_vars(&self) -> PathBuf {
        self.dir.join("efi-vars.fd")
    }
    pub fn log(&self) -> PathBuf {
        self.dir.join("qemu.log")
    }
    pub fn run_state(&self) -> PathBuf {
        self.dir.join("run.json")
    }
}

pub fn load(id: &str) -> Result<VmConfig, String> {
    let paths = VmPaths::new(id)?;
    let data = fs::read(paths.config()).map_err(|e| format!("VM não encontrada ({e})"))?;
    serde_json::from_slice(&data).map_err(|e| format!("config.json inválido: {e}"))
}

pub fn load_all() -> Vec<VmConfig> {
    let Ok(entries) = fs::read_dir(library_dir()) else { return Vec::new() };
    let mut configs: Vec<VmConfig> = entries
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter_map(|id| load(&id).ok())
        .collect();
    configs.sort_by_key(|c| c.created_at);
    configs
}

/// Grava num temporário e renomeia, para não deixar config.json pela metade.
pub fn save(config: &VmConfig) -> Result<(), String> {
    let paths = VmPaths::new(&config.id)?;
    fs::create_dir_all(&paths.dir).map_err(|e| e.to_string())?;
    let tmp = paths.dir.join("config.json.tmp");
    let data = serde_json::to_vec_pretty(config).map_err(|e| e.to_string())?;
    fs::write(&tmp, data).map_err(|e| e.to_string())?;
    fs::rename(&tmp, paths.config()).map_err(|e| e.to_string())
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// MAC no prefixo do QEMU (52:54:00), derivado do UUID para ser estável.
pub fn mac_for(id: &uuid::Uuid) -> String {
    let b = id.as_bytes();
    format!("52:54:00:{:02x}:{:02x}:{:02x}", b[0], b[1], b[2])
}
