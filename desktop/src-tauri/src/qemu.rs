//! Tudo que fala com o QEMU: achar os binários e o firmware, montar a linha de comando,
//! QMP (controle da VM ligada) e qemu-img (discos e snapshots).
use crate::vm::{GuestOs, VmConfig, VmPaths};
use serde_json::Value;
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    io::{BufRead, BufReader, Read, Write},
    net::{SocketAddr, TcpStream},
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

#[cfg(unix)]
use std::os::unix::net::UnixStream;
#[cfg(windows)]
use uds_windows::UnixStream;

/// Onde o QMP (controle da VM) escuta.
///
/// Socket Unix numa pasta só do usuário: outro usuário ou programa do computador não consegue
/// se conectar. Pelo TCP de antes, qualquer processo local controlava a VM sem senha — e o QMP
/// executa comandos (`migrate "exec:…"`). `Tcp` fica só para VMs ligadas por versões antigas.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QmpEndpoint {
    Unix(PathBuf),
    Tcp(u16),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Arch {
    X86_64,
    Aarch64,
}

impl Arch {
    pub fn host() -> Option<Arch> {
        match env::consts::ARCH {
            "x86_64" => Some(Arch::X86_64),
            "aarch64" => Some(Arch::Aarch64),
            _ => None,
        }
    }

    fn system_binary(self) -> &'static str {
        match self {
            Arch::X86_64 => "qemu-system-x86_64",
            Arch::Aarch64 => "qemu-system-aarch64",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Accel {
    Kvm,
    Whpx,
    Hvf,
    Tcg,
}

impl Accel {
    pub fn label(self) -> &'static str {
        match self {
            Accel::Kvm => "KVM",
            Accel::Whpx => "Windows Hypervisor Platform (WHPX)",
            Accel::Hvf => "Hypervisor.framework",
            Accel::Tcg => "emulação por software (lenta)",
        }
    }

    pub fn is_hardware(self) -> bool {
        self != Accel::Tcg
    }

    fn args(self) -> Vec<String> {
        let list: &[&str] = match self {
            Accel::Kvm => &["-accel", "kvm"],
            // Se a Plataforma do Hipervisor estiver desativada, o QEMU cai para o TCG.
            Accel::Whpx => &["-accel", "whpx,kernel-irqchip=off", "-accel", "tcg"],
            Accel::Hvf => &["-accel", "hvf"],
            Accel::Tcg => &["-accel", "tcg"],
        };
        list.iter().map(|s| s.to_string()).collect()
    }

    fn detect() -> Accel {
        if cfg!(target_os = "windows") {
            Accel::Whpx
        } else if cfg!(target_os = "macos") {
            Accel::Hvf
        } else if kvm_usable() {
            Accel::Kvm
        } else {
            Accel::Tcg
        }
    }
}

pub fn kvm_usable() -> bool {
    fs::OpenOptions::new().read(true).write(true).open("/dev/kvm").is_ok()
}

#[derive(Clone, Debug)]
pub struct Firmware {
    pub code: PathBuf,
    /// Modelo de variáveis EFI; sem ele, cria-se um arquivo zerado do tamanho do código.
    pub vars: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct Host {
    pub arch: Arch,
    pub accel: Accel,
    pub qemu: Option<PathBuf>,
    pub qemu_img: Option<PathBuf>,
    pub firmware: Option<Firmware>,
}

impl Host {
    pub fn detect() -> Result<Host, String> {
        let arch = Arch::host().ok_or_else(|| format!("Arquitetura não suportada: {}", env::consts::ARCH))?;
        let qemu = find_binary(arch.system_binary());
        let qemu_img = find_binary("qemu-img");
        let firmware = find_firmware(arch, qemu.as_deref());
        Ok(Host { arch, accel: Accel::detect(), qemu, qemu_img, firmware })
    }

    pub fn qemu(&self) -> Result<&Path, String> {
        self.qemu.as_deref().ok_or_else(|| missing_qemu_message())
    }

    pub fn qemu_img(&self) -> Result<&Path, String> {
        self.qemu_img.as_deref().ok_or_else(|| missing_qemu_message())
    }
}

pub fn missing_qemu_message() -> String {
    if cfg!(target_os = "windows") {
        "QEMU não encontrado. Instale pelo site qemu.org (Download → Windows) na pasta padrão e abra o VM Guave de novo.".into()
    } else if cfg!(target_os = "linux") {
        "QEMU não encontrado. Instale com: sudo apt install qemu-system-x86 qemu-utils ovmf (Debian/Ubuntu) ou sudo dnf install qemu-kvm qemu-img edk2-ovmf (Fedora).".into()
    } else {
        "QEMU não encontrado. Instale com: brew install qemu".into()
    }
}

fn exe(name: &str) -> String {
    if cfg!(target_os = "windows") { format!("{name}.exe") } else { name.to_string() }
}

/// O PATH de apps abertos pelo menu nem sempre inclui as pastas do QEMU; acrescenta as usuais.
fn search_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = env::var_os("PATH").map(|p| env::split_paths(&p).collect()).unwrap_or_default();
    if cfg!(target_os = "windows") {
        for var in ["ProgramFiles", "ProgramW6432"] {
            if let Some(p) = env::var_os(var) {
                dirs.push(PathBuf::from(p).join("qemu"));
            }
        }
    } else {
        dirs.extend(["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"].map(PathBuf::from));
    }
    dirs
}

pub fn find_binary(name: &str) -> Option<PathBuf> {
    let file = exe(name);
    search_dirs().into_iter().map(|d| d.join(&file)).find(|p| p.is_file())
}

fn find_firmware(arch: Arch, qemu: Option<&Path>) -> Option<Firmware> {
    let mut shares: Vec<PathBuf> = Vec::new();
    if let Some(bin_dir) = qemu.and_then(Path::parent) {
        shares.push(bin_dir.join("share")); // instalador oficial do Windows
        shares.push(bin_dir.join("../share/qemu"));
    }
    shares.extend(["/usr/share/qemu", "/usr/local/share/qemu", "/opt/homebrew/share/qemu"].map(PathBuf::from));

    let mut candidates: Vec<(PathBuf, Option<PathBuf>)> = Vec::new();
    match arch {
        Arch::X86_64 => {
            for s in &shares {
                candidates.push((s.join("edk2-x86_64-code.fd"), Some(s.join("edk2-i386-vars.fd"))));
            }
            // Pacotes OVMF de Debian/Ubuntu, Fedora e Arch.
            for (code, vars) in [
                ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
                ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
                ("/usr/share/edk2/ovmf/OVMF_CODE.fd", "/usr/share/edk2/ovmf/OVMF_VARS.fd"),
                ("/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.4m.fd"),
            ] {
                candidates.push((code.into(), Some(vars.into())));
            }
        }
        Arch::Aarch64 => {
            for s in &shares {
                candidates.push((s.join("edk2-aarch64-code.fd"), None));
            }
            for code in ["/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw"] {
                candidates.push((code.into(), None));
            }
        }
    }
    candidates
        .into_iter()
        .find(|(code, vars)| code.is_file() && vars.as_ref().map_or(true, |v| v.is_file()))
        .map(|(code, vars)| Firmware { code, vars })
}

/// Cria o arquivo de variáveis EFI da VM na primeira partida.
pub fn prepare_efi_vars(firmware: &Firmware, paths: &VmPaths) -> Result<(), String> {
    let target = paths.efi_vars();
    if target.exists() {
        return Ok(());
    }
    match &firmware.vars {
        Some(template) => fs::copy(template, &target).map(|_| ()),
        None => {
            let size = fs::metadata(&firmware.code).map_err(|e| e.to_string())?.len();
            fs::File::create(&target).and_then(|f| f.set_len(size))
        }
    }
    .map_err(|e| format!("Não foi possível criar as variáveis EFI: {e}"))
}

/// Vírgula separa opções no QEMU; dentro de um valor ela é escrita dobrada.
fn opt(path: &Path) -> String {
    path.to_string_lossy().replace(',', ",,")
}

pub fn uses_uefi(config: &VmConfig, host: &Host) -> bool {
    host.firmware.is_some() && (config.uefi || host.arch == Arch::Aarch64)
}

pub fn build_args(config: &VmConfig, paths: &VmPaths, host: &Host, qmp_socket: &Path) -> Result<Vec<String>, String> {
    let mut a: Vec<String> = Vec::new();
    let mut push = |items: &[&str]| a.extend(items.iter().map(|s| s.to_string()));

    push(&["-name", &format!("{} — VM Guave", config.name)]);
    push(&["-m", &format!("{}G", config.memory_gb), "-smp", &config.cpus.to_string()]);
    push(&["-machine", if host.arch == Arch::X86_64 { "q35" } else { "virt" }]);
    let cpu = if matches!(host.accel, Accel::Kvm | Accel::Hvf) { "host" } else { "max" };
    push(&["-cpu", cpu]);

    if host.arch == Arch::Aarch64 && host.firmware.is_none() {
        return Err("Firmware UEFI para ARM não encontrado (edk2-aarch64-code.fd ou AAVMF). Instale o pacote do QEMU com firmware.".into());
    }
    if uses_uefi(config, host) {
        let fw = host.firmware.as_ref().unwrap();
        push(&["-drive", &format!("if=pflash,format=raw,readonly=on,file={}", opt(&fw.code))]);
        push(&["-drive", &format!("if=pflash,format=raw,file={}", opt(&paths.efi_vars()))]);
    }

    let windows = config.os == GuestOs::Windows;
    let display = match (host.arch, windows) {
        (Arch::X86_64, false) => "virtio-vga",
        (Arch::X86_64, true) => "VGA",
        (Arch::Aarch64, false) => "virtio-gpu-pci",
        (Arch::Aarch64, true) => "ramfb",
    };
    push(&["-device", display]);
    push(&["-device", "qemu-xhci,id=xhci", "-device", "usb-tablet"]);
    if host.arch == Arch::Aarch64 {
        push(&["-device", "usb-kbd"]); // a máquina virt não tem teclado PS/2
    }

    // NVMe: Linux e Windows 10/11 têm driver nativo, então a instalação enxerga o disco sem drivers extras.
    let serial: String = config.id.chars().filter(|c| c.is_ascii_alphanumeric()).take(12).collect();
    // l2-cache-size: a tabela L2 inteira em memória (1 MB por 8 GB de disco com clusters de
    // 64 KB); sem isso, acesso aleatório em discos grandes relê metadados do arquivo.
    let l2_mb = ((config.disk_gb + 7) / 8).clamp(1, 32);
    push(&["-drive", &format!("if=none,id=hd0,file={},format=qcow2,discard=unmap,detect-zeroes=unmap,l2-cache-size={l2_mb}M", opt(&paths.disk()))]);
    push(&["-device", &format!("nvme,drive=hd0,serial=VMG{serial},bootindex=0")]);

    if let Some(iso) = config.iso.as_deref().filter(|s| !s.is_empty()) {
        let iso = Path::new(iso);
        if !iso.is_file() {
            return Err(format!("ISO não encontrada: {}", iso.display()));
        }
        // ISO é só leitura: sem trava, várias VMs (ou outro programa) podem usá-la ao mesmo tempo.
        push(&["-drive", &format!("if=none,id=cd0,media=cdrom,readonly=on,file.locking=off,file={}", opt(iso))]);
        // Disco vazio não dá boot, então o firmware passa para o CD; depois de instalado, o disco tem prioridade.
        let cd = if host.arch == Arch::X86_64 { "ide-cd,drive=cd0,bus=ide.1,bootindex=1" } else { "usb-storage,drive=cd0,removable=on,bootindex=1" };
        push(&["-device", cd]);
    }

    let forwards: String = config
        .port_forwards
        .iter()
        .map(|p| format!(",hostfwd=tcp:127.0.0.1:{}-:{}", p.host, p.guest))
        .collect();
    push(&["-netdev", &format!("user,id=net0{forwards}")]);
    let nic = if windows { "e1000e" } else { "virtio-net-pci" };
    push(&["-device", &format!("{nic},netdev=net0,mac={}", config.mac)]);

    push(&["-qmp", &format!("unix:{},server=on,wait=off", opt(qmp_socket))]);
    a.extend(host.accel.args());
    Ok(a)
}

/// Caminho do socket do QMP, numa pasta só do usuário. Sockets Unix aceitam caminhos curtos
/// (~100 bytes), por isso o nome usa só o começo do ID e a pasta fica perto da raiz:
/// - Linux: $XDG_RUNTIME_DIR/vm-guave (tmpfs do usuário); sem ele, <temp>/vm-guave-<usuário>.
/// - Windows: %LOCALAPPDATA%\vmg (só o usuário tem acesso ao AppData).
/// Se a pasta já existir e não for nossa, `set_permissions` falha e a VM não liga (melhor que
/// abrir o controle num lugar que outra pessoa enxerga).
pub fn qmp_socket_path(_paths: &VmPaths, id: &str) -> Result<PathBuf, String> {
    let short: String = id.chars().filter(|c| c.is_ascii_alphanumeric()).take(12).collect();
    #[cfg(unix)]
    let dir = {
        use std::os::unix::fs::PermissionsExt;
        let dir = match env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).filter(|p| p.is_dir()) {
            Some(runtime) => runtime.join("vm-guave"),
            None => {
                let user = env::var("USER").unwrap_or_else(|_| "user".into());
                env::temp_dir().join(format!("vm-guave-{user}"))
            }
        };
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("Pasta do controle da VM sem permissão própria ({}): {e}", dir.display()))?;
        dir
    };
    #[cfg(windows)]
    let dir = {
        let base = dirs::data_local_dir().ok_or("Pasta AppData\\Local não encontrada")?;
        let dir = base.join("vmg");
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        dir
    };
    let path = dir.join(format!("{short}.sock"));
    if path.as_os_str().len() > 100 {
        return Err(format!("Caminho longo demais para o socket do QMP: {}", path.display()));
    }
    Ok(path)
}

// MARK: QMP

type Reader = BufReader<Box<dyn Read + Send>>;
type Writer = Box<dyn Write + Send>;

fn connect(endpoint: &QmpEndpoint) -> Result<(Reader, Writer), String> {
    match endpoint {
        QmpEndpoint::Unix(path) => {
            let stream = UnixStream::connect(path).map_err(|e| e.to_string())?;
            stream.set_read_timeout(Some(Duration::from_secs(3))).ok();
            let reader: Box<dyn Read + Send> = Box::new(stream.try_clone().map_err(|e| e.to_string())?);
            Ok((BufReader::new(reader), Box::new(stream)))
        }
        QmpEndpoint::Tcp(port) => {
            let addr = SocketAddr::from(([127, 0, 0, 1], *port));
            let stream = TcpStream::connect_timeout(&addr, Duration::from_millis(400)).map_err(|e| e.to_string())?;
            stream.set_read_timeout(Some(Duration::from_secs(3))).ok();
            let reader: Box<dyn Read + Send> = Box::new(stream.try_clone().map_err(|e| e.to_string())?);
            Ok((BufReader::new(reader), Box::new(stream)))
        }
    }
}

/// Abre uma conexão QMP, negocia e executa um comando. Uma conexão por comando.
pub fn qmp(endpoint: &QmpEndpoint, command: &str) -> Result<Value, String> {
    let (mut reader, mut writer) = connect(endpoint)?;

    let greeting = read_reply(&mut reader)?;
    if greeting.get("QMP").is_none() {
        return Err("A porta não é um QMP do QEMU.".into());
    }
    send(&mut writer, r#"{"execute":"qmp_capabilities"}"#)?;
    read_reply(&mut reader)?;
    send(&mut writer, &format!(r#"{{"execute":"{command}"}}"#))?;
    read_reply(&mut reader)
}

fn send(writer: &mut Writer, line: &str) -> Result<(), String> {
    writer.write_all(format!("{line}\n").as_bytes()).map_err(|e| e.to_string())
}

/// Lê até a saudação, um "return" ou um "error"; eventos assíncronos são ignorados.
fn read_reply(reader: &mut Reader) -> Result<Value, String> {
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
            return Err("O QEMU fechou a conexão.".into());
        }
        let value: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
        if let Some(error) = value.get("error") {
            return Err(error["desc"].as_str().unwrap_or("erro do QMP").to_string());
        }
        if value.get("QMP").is_some() || value.get("return").is_some() {
            return Ok(value);
        }
    }
}

// MARK: qemu-img

fn run_img(img: &Path, args: &[&str]) -> Result<String, String> {
    let mut cmd = Command::new(img);
    cmd.args(args);
    no_console(&mut cmd);
    let out = cmd.output().map_err(|e| format!("Falha ao executar qemu-img: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

pub fn create_disk(img: &Path, path: &Path, size_gb: u32) -> Result<(), String> {
    // Clusters de 128 KB com subclusters: menos metadados e menos trabalho na 1ª gravação.
    run_img(img, &["create", "-q", "-f", "qcow2", "-o", "cluster_size=128k,extended_l2=on", &path.to_string_lossy(), &format!("{size_gb}G")]).map(|_| ())
}

pub fn resize_disk(img: &Path, path: &Path, size_gb: u32) -> Result<(), String> {
    run_img(img, &["resize", "-q", &path.to_string_lossy(), &format!("{size_gb}G")]).map(|_| ())
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub name: String,
    pub created_at: u64,
}

pub fn list_snapshots(img: &Path, disk: &Path) -> Result<Vec<Snapshot>, String> {
    // -U: lê mesmo com a VM ligada (o QEMU mantém o disco travado).
    let out = run_img(img, &["info", "-U", "--output=json", &disk.to_string_lossy()])?;
    let info: Value = serde_json::from_str(&out).map_err(|e| e.to_string())?;
    let list = info["snapshots"].as_array().cloned().unwrap_or_default();
    Ok(list
        .iter()
        .map(|s| Snapshot {
            name: s["name"].as_str().unwrap_or_default().to_string(),
            created_at: s["date-sec"].as_u64().unwrap_or(0),
        })
        .collect())
}

pub fn snapshot(img: &Path, disk: &Path, flag: &str, name: &str) -> Result<(), String> {
    run_img(img, &["snapshot", flag, name, &disk.to_string_lossy()]).map(|_| ())
}

/// No Windows, processos de console abririam uma janela preta por cima do app.
pub fn no_console(cmd: &mut Command) {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(target_os = "windows"))]
    let _ = cmd;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vm::PortForward;

    fn sample(os: GuestOs) -> VmConfig {
        VmConfig {
            id: "7e228f4c-1bf4-40a8-a154-a1731ad2673b".into(),
            name: "Teste".into(),
            os,
            cpus: 2,
            memory_gb: 4,
            disk_gb: 32,
            iso: None,
            mac: "52:54:00:12:34:56".into(),
            uefi: true,
            port_forwards: vec![PortForward { host: 2222, guest: 22 }],
            created_at: 0,
        }
    }

    fn host(arch: Arch, accel: Accel) -> Host {
        Host {
            arch,
            accel,
            qemu: None,
            qemu_img: None,
            firmware: Some(Firmware { code: "/fw/code,1.fd".into(), vars: None }),
        }
    }

    #[test]
    fn x86_linux_args() {
        let cfg = sample(GuestOs::Linux);
        let paths = VmPaths::new(&cfg.id).unwrap();
        let args = build_args(&cfg, &paths, &host(Arch::X86_64, Accel::Kvm), Path::new("/run/user/1000/vm-guave/abc.sock")).unwrap().join(" ");
        assert!(args.contains("-machine q35"));
        assert!(args.contains("-cpu host"));
        assert!(args.contains("file=/fw/code,,1.fd"), "vírgula escapada");
        assert!(args.contains("virtio-vga"));
        assert!(args.contains("virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56"));
        assert!(args.contains("hostfwd=tcp:127.0.0.1:2222-:22"));
        assert!(args.contains("-qmp unix:/run/user/1000/vm-guave/abc.sock,server=on,wait=off"));
        assert!(!args.contains("-qmp tcp"), "QMP não pode ficar em TCP");
        assert!(args.contains("l2-cache-size=4M"), "cache L2 para o disco de 32 GB");
        assert!(args.ends_with("-accel kvm"));
    }

    #[test]
    fn windows_guest_on_whpx() {
        let mut cfg = sample(GuestOs::Windows);
        cfg.uefi = false;
        let paths = VmPaths::new(&cfg.id).unwrap();
        let args = build_args(&cfg, &paths, &host(Arch::X86_64, Accel::Whpx), Path::new("/tmp/q.sock")).unwrap().join(" ");
        assert!(!args.contains("pflash"), "BIOS quando UEFI desligado");
        assert!(args.contains("-device VGA"));
        assert!(args.contains("e1000e"));
        assert!(args.contains("-cpu max"));
        assert!(args.contains("-accel whpx,kernel-irqchip=off -accel tcg"));
    }

    #[test]
    fn missing_iso_is_an_error() {
        let mut cfg = sample(GuestOs::Linux);
        cfg.iso = Some("/nao/existe.iso".into());
        let paths = VmPaths::new(&cfg.id).unwrap();
        assert!(build_args(&cfg, &paths, &host(Arch::Aarch64, Accel::Hvf), Path::new("/tmp/q.sock")).is_err());
    }

    #[test]
    fn rejects_path_traversal() {
        assert!(VmPaths::new("../../etc").is_err());
    }

    /// Liga uma VM de verdade com o QEMU instalado. Rodar com:
    /// VMGUAVE_TEST_ISO=/caminho.iso cargo test -- --ignored --nocapture
    #[test]
    #[ignore]
    fn boots_real_vm() {
        let Some(iso) = env::var_os("VMGUAVE_TEST_ISO") else { return };
        let home = env::temp_dir().join(format!("vmguave-test-{}", std::process::id()));
        env::set_var("VMGUAVE_HOME", &home);

        let host = Host::detect().unwrap();
        let img = host.qemu_img().unwrap().to_path_buf();
        let mut cfg = sample(GuestOs::Linux);
        cfg.iso = Some(iso.to_string_lossy().into_owned());
        let paths = VmPaths::new(&cfg.id).unwrap();
        fs::create_dir_all(&paths.dir).unwrap();
        create_disk(&img, &paths.disk(), 16).unwrap();
        prepare_efi_vars(host.firmware.as_ref().unwrap(), &paths).unwrap();

        snapshot(&img, &paths.disk(), "-c", "limpo").unwrap();
        assert_eq!(list_snapshots(&img, &paths.disk()).unwrap()[0].name, "limpo");

        let socket = qmp_socket_path(&paths, &cfg.id).unwrap();
        let endpoint = QmpEndpoint::Unix(socket.clone());
        let args = build_args(&cfg, &paths, &host, &socket).unwrap();
        println!("{} {}", host.qemu().unwrap().display(), args.join(" "));
        let mut child = Command::new(host.qemu().unwrap())
            .args(&args)
            .args(["-display", "none"])
            .spawn()
            .unwrap();

        let mut status = Err(String::new());
        for _ in 0..30 {
            std::thread::sleep(Duration::from_millis(300));
            status = qmp(&endpoint, "query-status");
            if status.is_ok() {
                break;
            }
        }
        assert_eq!(status.unwrap()["return"]["status"], "running");
        qmp(&endpoint, "stop").unwrap();
        assert_eq!(qmp(&endpoint, "query-status").unwrap()["return"]["status"], "paused");
        qmp(&endpoint, "cont").unwrap();
        qmp(&endpoint, "system_reset").unwrap();
        // Snapshots exigem a VM desligada (o disco fica travado).
        assert!(snapshot(&img, &paths.disk(), "-c", "ligada").is_err());
        let _ = qmp(&endpoint, "quit");
        assert!(child.wait().unwrap().success());
        snapshot(&img, &paths.disk(), "-d", "limpo").unwrap();
        fs::remove_dir_all(&home).unwrap();
    }
}
