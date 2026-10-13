// Klipperizer — lógica do painel touch

let placas = [];
let perfilAtual = null;
let evtSource = null;
let pollTimer = null;

const $ = (id) => document.getElementById(id);

function mostrarTela(id) {
  document.querySelectorAll(".tela").forEach((t) => t.classList.add("oculta"));
  $(id).classList.remove("oculta");
}

function setBadge(classe, texto) {
  const b = $("status-badge");
  b.className = "badge " + classe;
  b.textContent = texto;
}

async function carregarPlacas() {
  const resp = await fetch("/api/boards");
  placas = await resp.json();
  renderPlacas("");
}

function renderPlacas(cat) {
  const grade = $("grade-placas");
  grade.innerHTML = "";
  placas
    .filter((p) => !cat || p.categoria === cat)
    .forEach((p) => {
      const btn = document.createElement("button");
      btn.className = "placa-card";
      btn.innerHTML = `${p.nome}<span class="cat">${p.categoria}</span>`;
      btn.onclick = () => escolherPlaca(p);
      grade.appendChild(btn);
    });
}

function escolherPlaca(p) {
  perfilAtual = p;
  $("nome-placa").textContent = p.nome;
  mostrarTela("tela-modo");
}

function voltarPlacas() {
  mostrarTela("tela-placas");
}

async function escolherModo(modo) {
  $("exec-titulo").textContent = `${perfilAtual.nome} — ${modo.toUpperCase()}`;
  mostrarTela("tela-execucao");
  $("log").textContent = "";
  $("avisos").classList.add("oculta");
  setBadge("running", "Executando...");

  const resp = await fetch("/api/start", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ perfil: perfilAtual.arquivo, modo }),
  });
  const data = await resp.json();
  if (!resp.ok) {
    $("log").textContent = "ERRO: " + (data.erro || "falha ao iniciar");
    setBadge("erro", "Erro");
    return;
  }
  conectarLog();
}

function conectarLog() {
  if (evtSource) evtSource.close();
  evtSource = new EventSource("/api/log");
  evtSource.onmessage = (e) => {
    const { line } = JSON.parse(e.data);
    const log = $("log");
    log.textContent += line + "\n";
    log.scrollTop = log.scrollHeight;
    // Destaca o aviso de DFU no log e mostra o bloco de avisos
    if (/AVISO/.test(line)) $("avisos").classList.remove("oculta");
  };
  pollStatus();
}

function pollStatus() {
  clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    const resp = await fetch("/api/status");
    const st = await resp.json();
    if (!st.running) {
      clearInterval(pollTimer);
      if (evtSource) evtSource.close();
      if (st.returncode === 0) setBadge("ok", "Concluído");
      else setBadge("erro", "Falhou");
    }
  }, 2000);
}

document.querySelectorAll(".filtro").forEach((f) => {
  f.onclick = () => {
    document.querySelectorAll(".filtro").forEach((x) => x.classList.remove("ativo"));
    f.classList.add("ativo");
    renderPlacas(f.dataset.cat);
  };
});

carregarPlacas();
