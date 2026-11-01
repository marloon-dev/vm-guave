// Interface do VM Guave. Fala com o backend Rust por invoke(); o estado é relido a cada 2 s.
const { invoke } = window.__TAURI__.core;
const dialogApi = window.__TAURI__.dialog;

const $ = (id) => document.getElementById(id);
const STATE_LABEL = { stopped: "Desligada", starting: "Ligando…", running: "Em execução", paused: "Pausada" };
const OS_LABEL = { linux: "Linux", windows: "Windows" };

let vms = [];
let selectedId = null;
let editing = null; // VM sendo editada no diálogo (null = criando)
let busy = false;

// MARK: Utilitários

function toast(message, isError = false) {
  const el = $("toast");
  el.textContent = message;
  el.classList.toggle("error", isError);
  el.classList.remove("hidden");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => el.classList.add("hidden"), isError ? 9000 : 3500);
}

async function call(command, args = {}, success) {
  if (busy) return false;
  busy = true;
  render();
  try {
    await invoke(command, args);
    if (success) toast(success);
    return true;
  } catch (error) {
    toast(String(error), true);
    return false;
  } finally {
    busy = false;
    await refresh();
  }
}

function el(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  Object.assign(node, props);
  for (const child of children) node.append(child);
  return node;
}

function selected() {
  return vms.find((vm) => vm.id === selectedId);
}

// MARK: Lista e detalhes

async function refresh() {
  try {
    vms = await invoke("list_vms");
  } catch (error) {
    toast(String(error), true);
  }
  if (!selected()) selectedId = vms[0]?.id ?? null;
  render();
}

function render() {
  const list = $("vm-list");
  list.replaceChildren(
    ...vms.map((vm) => {
      const li = el("li", { className: vm.id === selectedId ? "selected" : "" }, [
        el("span", { className: `dot ${vm.state}` }),
        el("span", { className: "name", textContent: vm.name }),
      ]);
      li.addEventListener("click", () => {
        selectedId = vm.id;
        render();
        loadSnapshots();
      });
      return li;
    }),
  );
  $("empty-list").classList.toggle("hidden", vms.length > 0);

  const vm = selected();
  $("placeholder").classList.toggle("hidden", !!vm);
  $("vm-detail").classList.toggle("hidden", !vm);
  if (!vm) return;

  $("d-name").textContent = vm.name;
  const badge = $("d-state");
  badge.textContent = STATE_LABEL[vm.state];
  badge.className = `badge ${vm.state}`;
  $("d-os").textContent = OS_LABEL[vm.os] + (vm.uefi ? " · UEFI" : " · BIOS");
  $("d-cpus").textContent = vm.cpus;
  $("d-mem").textContent = `${vm.memoryGb} GB`;
  $("d-disk").textContent = `${vm.diskGb} GB`;
  $("d-iso").textContent = vm.iso || "Nenhuma";
  $("d-ports").textContent = vm.portForwards.length
    ? vm.portForwards.map((p) => `localhost:${p.host} → ${p.guest}`).join(", ")
    : "Nenhuma";

  const stopped = vm.state === "stopped";
  $("d-hint").textContent = stopped
    ? vm.iso
      ? "Depois de instalar o sistema, remova a ISO em Configurações."
      : ""
    : "A tela da VM abre numa janela própria do QEMU. Clique nela para capturar o mouse; Ctrl+Alt+G solta.";

  const actions = $("power-actions");
  const button = (label, handler, opts = {}) => {
    const b = el("button", { textContent: label, className: opts.className || "", disabled: busy || opts.disabled });
    b.addEventListener("click", handler);
    return b;
  };
  const id = vm.id;
  if (stopped) {
    actions.replaceChildren(button("▶ Iniciar", () => call("start_vm", { id }), { className: "primary" }));
  } else {
    actions.replaceChildren(
      vm.state === "paused"
        ? button("Continuar", () => call("resume_vm", { id }))
        : button("Pausar", () => call("pause_vm", { id }), { disabled: vm.state !== "running" }),
      button("Reiniciar", () => call("reset_vm", { id })),
      button("Desligar", () => call("stop_vm", { id, force: false }, "Sinal de desligar enviado ao sistema.")),
      button("Forçar", forceStop, { className: "danger" }),
    );
  }

  for (const b of ["edit-vm", "delete-vm"]) $(b).disabled = busy || !stopped;
  $("snapshot-form").querySelector("button").disabled = busy || !stopped;
}

async function forceStop() {
  const vm = selected();
  const ok = await dialogApi.ask(`Desligar "${vm.name}" na hora? É como tirar da tomada: o que não foi salvo se perde.`, {
    title: "Forçar desligamento",
    kind: "warning",
  });
  if (ok) call("stop_vm", { id: vm.id, force: true });
}

// MARK: Snapshots

async function loadSnapshots() {
  const vm = selected();
  const list = $("snapshot-list");
  if (!vm) return list.replaceChildren();
  let snapshots = [];
  try {
    snapshots = await invoke("list_snapshots", { id: vm.id });
  } catch (error) {
    return list.replaceChildren(el("li", { className: "muted", textContent: String(error) }));
  }
  if (!snapshots.length) return list.replaceChildren(el("li", { className: "muted", textContent: "Nenhum snapshot." }));

  list.replaceChildren(
    ...snapshots.map((s) => {
      const when = s.createdAt ? new Date(s.createdAt * 1000).toLocaleString("pt-BR") : "";
      const restore = el("button", { textContent: "Restaurar" });
      restore.addEventListener("click", async () => {
        const ok = await dialogApi.ask(`Voltar o disco para "${s.name}"? Tudo o que mudou depois dele se perde.`, {
          title: "Restaurar snapshot",
          kind: "warning",
        });
        if (ok && (await call("restore_snapshot", { id: vm.id, name: s.name }, "Snapshot restaurado."))) loadSnapshots();
      });
      const remove = el("button", { textContent: "Excluir", className: "danger" });
      remove.addEventListener("click", async () => {
        if (await call("delete_snapshot", { id: vm.id, name: s.name }, "Snapshot excluído.")) loadSnapshots();
      });
      return el("li", {}, [el("span", { textContent: `${s.name}  ·  ${when}` }), restore, remove]);
    }),
  );
}

$("snapshot-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const vm = selected();
  const name = $("snapshot-name").value.trim();
  if (!vm || !name) return;
  if (await call("create_snapshot", { id: vm.id, name }, "Snapshot criado.")) {
    $("snapshot-name").value = "";
    loadSnapshots();
  }
});

// MARK: Diálogo de criar/editar

const form = $("vm-form");

function openDialog(vm) {
  editing = vm || null;
  const cores = navigator.hardwareConcurrency || 4;
  form.reset();
  $("dialog-error").classList.add("hidden");
  $("dialog-title").textContent = vm ? `Configurações de ${vm.name}` : "Nova VM";
  $("save-dialog").textContent = vm ? "Salvar" : "Criar VM";
  $("edit-only").classList.toggle("hidden", !vm);
  form.cpus.max = cores;
  form.os.disabled = !!vm;
  form.name.value = vm?.name ?? "";
  form.os.value = vm?.os ?? "linux";
  form.iso.value = vm?.iso ?? "";
  form.cpus.value = vm?.cpus ?? Math.max(1, Math.min(4, Math.floor(cores / 2)));
  form.memoryGb.value = vm?.memoryGb ?? 4;
  form.diskGb.value = vm?.diskGb ?? 64;
  form.diskGb.min = vm?.diskGb ?? 8;
  form.uefi.checked = vm?.uefi ?? true;
  form.ports.value = (vm?.portForwards ?? []).map((p) => `${p.host}:${p.guest}`).join("\n");
  updateNote();
  $("vm-dialog").showModal();
  form.name.focus();
}

function updateNote() {
  const windows = form.os.value === "windows";
  $("dialog-note").textContent = editing
    ? "O disco só pode crescer. Depois, amplie a partição dentro do sistema convidado."
    : windows
      ? "Windows: use a ISO oficial da Microsoft (x64). Recomendado: 4+ CPUs, 8 GB de memória e 64 GB de disco."
      : "Linux: qualquer ISO x64 (Ubuntu, Fedora, Debian…). O disco cresce conforme o uso.";
  if (!editing && windows && Number(form.memoryGb.value) < 8) form.memoryGb.value = 8;
}
form.os.addEventListener("change", updateNote);

$("pick-iso").addEventListener("click", async () => {
  const path = await dialogApi.open({
    multiple: false,
    directory: false,
    filters: [{ name: "Imagem de disco", extensions: ["iso", "img"] }],
  });
  if (path) form.iso.value = path;
});
$("clear-iso").addEventListener("click", () => (form.iso.value = ""));
$("cancel-dialog").addEventListener("click", () => $("vm-dialog").close());

function parsePorts(text) {
  return text
    .split(/\n|,/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const match = line.match(/^(\d{1,5})\s*:\s*(\d{1,5})$/);
      if (!match) throw new Error(`Porta inválida: "${line}". Use computador:VM, ex.: 2222:22.`);
      const [host, guest] = [Number(match[1]), Number(match[2])];
      if (host > 65535 || guest > 65535) throw new Error(`Porta fora do intervalo: "${line}".`);
      return { host, guest };
    });
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const errorBox = $("dialog-error");
  errorBox.classList.add("hidden");
  const values = {
    name: form.name.value.trim(),
    iso: form.iso.value || null,
    cpus: Number(form.cpus.value),
    memoryGb: Number(form.memoryGb.value),
    diskGb: Number(form.diskGb.value),
  };
  $("save-dialog").disabled = true;
  try {
    if (editing) {
      const config = { ...editing, ...values, uefi: form.uefi.checked, portForwards: parsePorts(form.ports.value) };
      delete config.state;
      await invoke("update_vm", { config });
      toast("Configurações salvas.");
    } else {
      const created = await invoke("create_vm", { request: { ...values, os: form.os.value } });
      selectedId = created.id;
      toast(`"${created.name}" criada. Clique em Iniciar para instalar o sistema.`);
    }
    $("vm-dialog").close();
    await refresh();
    loadSnapshots();
  } catch (error) {
    errorBox.textContent = error instanceof Error ? error.message : String(error);
    errorBox.classList.remove("hidden");
  } finally {
    $("save-dialog").disabled = false;
  }
});

// MARK: Botões gerais

$("new-vm").addEventListener("click", () => openDialog(null));
$("edit-vm").addEventListener("click", () => openDialog(selected()));
$("open-folder").addEventListener("click", () => call("open_vm_folder", { id: selectedId }));
$("delete-vm").addEventListener("click", async () => {
  const vm = selected();
  const ok = await dialogApi.ask(`Excluir "${vm.name}" e o disco dela? Não dá para desfazer.`, {
    title: "Excluir VM",
    kind: "warning",
  });
  if (ok && (await call("delete_vm", { id: vm.id }, "VM excluída."))) {
    selectedId = null;
    await refresh();
    loadSnapshots();
  }
});

// MARK: Início

async function loadHost() {
  try {
    const host = await invoke("host_info");
    $("warnings").replaceChildren(...host.warnings.map((w) => el("p", { className: "warning", textContent: w })));
    $("host-summary").textContent = `${host.os} ${host.arch} · ${host.accel}` + (host.qemu ? "" : " · sem QEMU");
    $("host-summary").title = `VMs em ${host.libraryDir}`;
  } catch (error) {
    toast(String(error), true);
  }
}

loadHost();
refresh().then(loadSnapshots);
setInterval(() => {
  if (!busy && !document.hidden) refresh();
}, 2000);
