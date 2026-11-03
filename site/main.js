// Detecta o sistema do visitante, destaca o download certo e busca os arquivos da última versão
// na API do GitHub. Sem JS, todos os botões levam à página de Releases.
(() => {
  const REPO = "marloon-dev/vm-guave";

  const ICONS = {
    mac: '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M16.4 12.6c0-2.4 2-3.6 2.1-3.7-1.2-1.7-3-1.9-3.6-2-1.5-.2-3 .9-3.8.9-.8 0-2-.9-3.3-.9-1.7 0-3.3 1-4.2 2.6-1.8 3.1-.5 7.7 1.3 10.2.9 1.2 1.9 2.6 3.2 2.6 1.3-.1 1.8-.8 3.3-.8s2 .8 3.3.8c1.4 0 2.3-1.3 3.1-2.5 1-1.4 1.4-2.8 1.4-2.9 0 0-2.8-1.1-2.8-4.3ZM13.9 5.3c.7-.8 1.2-2 1-3.2-1 .1-2.2.7-3 1.5-.6.7-1.2 1.9-1 3.1 1.1.1 2.3-.6 3-1.4Z"/></svg>',
    windows: '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M3 5.1 10.4 4v7.1H3V5.1Zm8.3-1.2L21 2.5v8.6h-9.7V3.9ZM3 12.9h7.4V20L3 18.9v-6Zm8.3 0H21v8.6l-9.7-1.4v-7.2Z"/></svg>',
    linux: '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M12 2c-2.2 0-3.6 1.9-3.6 4.6 0 1.3.3 2.2-.4 3.6-1 1.9-2.9 4.3-2.9 6.6 0 .8.2 1.4.6 1.9-.5.4-1.2.6-1.2 1.4 0 1 1.5 1.3 3.4 1.6 1.2.2 2 .4 2.6.4.6 0 .9-.2 1.5-.2s.9.2 1.5.2c.6 0 1.4-.2 2.6-.4 1.9-.3 3.4-.6 3.4-1.6 0-.8-.7-1-1.2-1.4.4-.5.6-1.1.6-1.9 0-2.3-1.9-4.7-2.9-6.6-.7-1.4-.4-2.3-.4-3.6C15.6 3.9 14.2 2 12 2Z"/></svg>',
  };

  const OS_INFO = {
    mac: { label: "Baixar para macOS", note: "Apple Silicon · macOS 14 ou mais recente", asset: "dmg" },
    windows: { label: "Baixar para Windows", note: "Windows 10 ou 11 (64 bits) · requer o QEMU", asset: "exe" },
    linux: { label: "Baixar para Linux", note: "Pacotes .deb, .rpm e AppImage", asset: null },
  };

  // Padrões dos nomes dos arquivos gerados pelo workflow de release.
  const ASSET_PATTERNS = {
    dmg: /\.dmg$/i,
    exe: /x64-setup\.exe$/i,
    msi: /\.msi$/i,
    deb: /\.deb$/i,
    rpm: /\.rpm$/i,
    appimage: /\.AppImage$/i,
  };

  function detectOS() {
    const platform = (navigator.userAgentData?.platform || navigator.platform || "").toLowerCase();
    const ua = navigator.userAgent.toLowerCase();
    if (/android|iphone|ipad|ipod/.test(ua)) return null; // celular: mostra todas as opções
    if (platform.includes("mac") || ua.includes("mac os")) return "mac";
    if (platform.includes("win") || ua.includes("windows")) return "windows";
    if (platform.includes("linux") || ua.includes("linux")) return "linux";
    return null;
  }

  function formatSize(bytes) {
    const mb = bytes / 1048576;
    return mb >= 10 ? `${Math.round(mb)} MB` : `${mb.toFixed(1).replace(".", ",")} MB`;
  }

  const os = detectOS();
  const heroButton = document.getElementById("hero-download");

  if (os) {
    const info = OS_INFO[os];
    document.getElementById("hero-label").textContent = info.label;
    document.getElementById("hero-note").innerHTML =
      `${info.note} · <a href="#download">outras plataformas</a>`;
    document.querySelector("[data-os-icon]").innerHTML = ICONS[os];
    document.getElementById(`dl-${os}`)?.classList.add("is-current");
  }

  async function loadRelease() {
    try {
      const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!response.ok) return;
      const release = await response.json();

      const version = release.tag_name?.replace(/^v/, "");
      if (version) {
        document.querySelectorAll("[data-version]").forEach((el) => (el.textContent = `Versão ${version}`));
      }

      const found = {};
      for (const [key, pattern] of Object.entries(ASSET_PATTERNS)) {
        const asset = release.assets.find((a) => pattern.test(a.name));
        if (asset) found[key] = asset;
      }

      document.querySelectorAll("[data-asset]").forEach((link) => {
        const asset = found[link.dataset.asset];
        if (!asset) return;
        link.href = asset.browser_download_url;
        const size = link.querySelector(".size");
        if (size) size.textContent = `· ${formatSize(asset.size)}`;
      });

      // O botão principal baixa direto quando há um arquivo único para o sistema.
      const direct = os && OS_INFO[os].asset && found[OS_INFO[os].asset];
      if (direct) heroButton.href = direct.browser_download_url;
    } catch {
      // Sem rede ou limite da API: os links continuam apontando para a página de Releases.
    }
  }
  loadRelease();

  // Borda no cabeçalho depois de rolar.
  const header = document.querySelector(".site-header");
  const onScroll = () => header.classList.toggle("scrolled", window.scrollY > 8);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // Animação de entrada das seções.
  const items = document.querySelectorAll(".reveal");
  if (!("IntersectionObserver" in window)) {
    items.forEach((el) => el.classList.add("visible"));
    return;
  }
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
          observer.unobserve(entry.target);
        }
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.08 },
  );
  items.forEach((el) => observer.observe(el));

  // Abas da seção Novidades: clique ou setas do teclado trocam a captura.
  const tabs = [...document.querySelectorAll('.tab-list [role="tab"]')];
  function selectTab(tab, focus) {
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute("aria-selected", on);
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    });
    if (focus) tab.focus();
  }
  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => selectTab(tab, false));
    tab.addEventListener("keydown", (event) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
      if (event.key === "Home") selectTab(tabs[0], true);
      else if (event.key === "End") selectTab(tabs[tabs.length - 1], true);
      else if (step) selectTab(tabs[(i + step + tabs.length) % tabs.length], true);
      else return;
      event.preventDefault();
    });
  });
})();
