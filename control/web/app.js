"use strict";
// LLM 관리판 화면. 서버 API(/api)를 2초마다 읽어 그린다. 빌드 과정 없음.

const STATE = {
  stopped: "꺼짐", starting: "켜는 중", ready: "준비됨", unresponsive: "응답 없음", failed: "실패", stopping: "끄는 중",
};
const $ = (sel, root = document) => root.querySelector(sel);
const el = (tag, attrs = {}, ...kids) => {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") n.className = v;
    else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
    else if (k === "text") n.textContent = v;
    else n.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) n.append(kid);
  return n;
};

let token = "";
try { token = localStorage.getItem("llmctl-token") || ""; } catch (_) {}
// A link like http://server:8700/#token=... logs in once; the hash never reaches the server and is removed at once.
const fromLink = new URLSearchParams(location.hash.slice(1)).get("token");
if (fromLink) {
  token = fromLink;
  try { localStorage.setItem("llmctl-token", token); } catch (_) {}
  history.replaceState(null, "", location.pathname);
}
let state = null;
let scripts = [];
let tab = "dash";

async function api(path, opts = {}) {
  const r = await fetch(path, {
    ...opts,
    headers: { "Authorization": `Bearer ${token}`, ...(opts.body ? { "Content-Type": "application/json" } : {}) },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  if (r.status === 401) { showLogin("토큰이 맞지 않습니다."); throw new Error("401"); }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.detail || `HTTP ${r.status}`);
  return data;
}

function toast(msg, bad = false) {
  const t = $("#toast");
  t.textContent = msg; t.className = "toast" + (bad ? " bad" : ""); t.hidden = false;
  clearTimeout(toast.timer); toast.timer = setTimeout(() => { t.hidden = true; }, bad ? 7000 : 2500);
}

function confirmBox(text) {
  return new Promise((resolve) => {
    const d = $("#confirm");
    $("#confirm-text").textContent = text;
    const done = (v) => { d.close(); resolve(v); };
    $("#confirm-yes").onclick = () => done(true);
    $("#confirm-no").onclick = () => done(false);
    d.showModal();
  });
}

const ago = (t) => {
  if (!t) return "";
  const s = Math.max(0, Math.floor(Date.now() / 1000 - t));
  if (s < 60) return `${s}초`;
  if (s < 3600) return `${Math.floor(s / 60)}분`;
  if (s < 86400) return `${Math.floor(s / 3600)}시간 ${Math.floor((s % 3600) / 60)}분`;
  return `${Math.floor(s / 86400)}일 ${Math.floor((s % 86400) / 3600)}시간`;
};
const gib = (mib) => (mib / 1024).toFixed(1);

// ---- login -----------------------------------------------------------------------------------------------------
function showLogin(msg) {
  $("#app").hidden = true; $("#login").hidden = false;
  const e = $("#login-error"); e.hidden = !msg; e.textContent = msg || "";
}
$("#login-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  token = $("#token-input").value.trim();
  try { localStorage.setItem("llmctl-token", token); } catch (_) {}
  start();
});
$("#logout").onclick = () => { token = ""; try { localStorage.removeItem("llmctl-token"); } catch (_) {} showLogin(); };

// ---- tabs ------------------------------------------------------------------------------------------------------
$("#tabs").addEventListener("click", (ev) => {
  const b = ev.target.closest("button[data-tab]");
  if (!b) return;
  tab = b.dataset.tab;
  for (const x of $("#tabs").children) x.classList.toggle("active", x === b);
  for (const t of ["dash", "envs", "connect"]) $(`#tab-${t}`).hidden = t !== tab;
  if (tab === "envs") loadEnvs();
  if (tab === "connect") drawConnect();
});

// ---- dashboard -------------------------------------------------------------------------------------------------
function meter(label, value, max, unit, fmt = (v) => v) {
  const pct = max ? Math.min(100, (value / max) * 100) : 0;
  return el("div", { class: "meter" },
    el("div", { class: "meter-label" }, el("span", { text: label }), el("span", { text: `${fmt(value)}${unit}` })),
    el("div", { class: "bar" }, el("span", { class: pct > 95 ? "full" : pct > 85 ? "hot" : "", style: `width:${pct}%` })));
}

function drawGpus() {
  const box = $("#gpus");
  box.replaceChildren();
  if (!state.gpus.length) {
    box.append(el("div", { class: "card muted", text: "GPU 정보를 읽지 못했습니다. 이 서버에 NVIDIA 드라이버(nvidia-smi)가 있는지 확인하세요." }));
    return;
  }
  for (const g of state.gpus) {
    const procs = g.procs.map((p) => el("div", {},
      `${p.instance ? p.instance : "관리 밖"} · pid ${p.pid} · ${gib(p.mem || 0)} GiB`));
    box.append(el("div", { class: "card" },
      el("div", { class: "gpu-head" }, el("span", { text: `GPU ${g.index}` }), el("span", { class: "muted", text: g.name })),
      meter("사용률", g.util ?? 0, 100, "%", (v) => v.toFixed(0)),
      meter("메모리", g.mem_used ?? 0, g.mem_total ?? 1, ` / ${gib(g.mem_total ?? 0)} GiB`, gib),
      el("div", { class: "facts", style: "margin-top:8px" },
        el("span", {}, "온도 ", el("b", { text: `${g.temp ?? "-"}°C` })),
        el("span", {}, "전력 ", el("b", { text: `${(g.power ?? 0).toFixed(0)} / ${(g.power_limit ?? 0).toFixed(0)} W` }))),
      procs.length ? el("div", { class: "gpu-procs" }, procs) : el("div", { class: "gpu-procs", text: "쓰는 프로세스 없음" })));
  }
}

function drawNotices() {
  const o = $("#orphans");
  o.replaceChildren();
  if (state.orphans.length) {
    o.append(el("div", { class: "notice" },
      el("strong", { text: "관리판 밖에서 GPU를 쓰는 프로세스가 있습니다." }),
      el("div", { class: "small muted", text: "예전 방식으로 띄운 서버이거나 남은 작업자일 수 있습니다. 같은 GPU에 인스턴스를 켜면 메모리가 모자랄 수 있습니다." }),
      ...state.orphans.map((p) => el("div", { class: "mono small" },
        `GPU ${p.gpu} · pid ${p.pid} · ${gib(p.mem || 0)} GiB · ${p.cmd || p.name}`))));
  }
  const e = $("#load-errors");
  e.replaceChildren();
  for (const [name, msg] of Object.entries(state.errors || {})) {
    e.append(el("div", { class: "notice bad" }, el("strong", { text: `instances/${name}.yaml을 읽지 못했습니다: ` }), msg));
  }
}

function instCard(i) {
  const busy = ["starting", "stopping"].includes(i.state);
  const running = ["starting", "ready", "unresponsive", "stopping"].includes(i.state);
  const facts = [
    ["모델", i.model || "-"], ["서빙 이름", i.served_name || "-"], ["포트", i.port ?? "-"],
    ["GPU", i.gpus.join(", ") || "-"], ["스크립트", i.script],
  ];
  if (running && i.gpu_mem) facts.push(["GPU 메모리", `${gib(i.gpu_mem)} GiB`]);
  if (i.state === "ready" && i.ready_since) facts.push(["준비된 지", ago(i.ready_since)]);
  if (i.state === "starting" && i.since) facts.push(["켜기 시작한 지", ago(i.since)]);
  const act = (label, fn, cls = "") => el("button", { class: cls, onclick: fn }, label);
  const buttons = [];
  if (!running) buttons.push(act("시작", () => doAction(i, "start"), "primary"));
  if (running) buttons.push(act("끄기", () => doAction(i, "stop")));
  if (running && !busy) buttons.push(act("재시작", () => doAction(i, "restart")));
  if (i.state === "ready") buttons.push(act("시험 대화", () => openChat(i.served?.[0] || i.served_name)));
  buttons.push(act("로그", () => openLogs(i.name), "ghost"));
  buttons.push(act("편집", () => openEditor(i.name), "ghost"));
  buttons.push(act("복제", () => openEditor(i.name, true), "ghost"));
  return el("div", { class: "card inst" },
    el("div", { class: "inst-head" },
      el("span", { class: "inst-name", text: i.name }),
      el("span", { class: `pill ${i.state}`, text: STATE[i.state] || i.state }),
      i.state === "failed" && i.code !== null ? el("span", { class: "muted small", text: `종료 코드 ${i.code}` }) : null,
      i.drift ? el("span", { class: "badge", text: "설정이 바뀜, 재시작해야 반영" }) : null,
      i.autostart ? el("span", { class: "muted small", text: "자동 시작" }) : null),
    i.description ? el("div", { class: "muted", text: i.description }) : null,
    el("div", { class: "facts" }, facts.map(([k, v]) => el("span", {}, `${k} `, el("b", { text: String(v) })))),
    i.state === "unresponsive" ? el("div", { class: "notice", text: "준비됐던 엔진이 응답하지 않습니다. 긴 요청을 처리 중이거나 멈췄을 수 있습니다. 로그를 확인하세요." }) : null,
    i.state === "failed" && i.error_tail ? el("pre", { class: "tail", text: i.error_tail }) : null,
    el("div", { class: "actions" }, buttons));
}

function drawInstances() {
  const box = $("#instances");
  box.replaceChildren();
  if (!state.instances.length) {
    box.append(el("div", { class: "card empty", text: "인스턴스가 없습니다. ‘인스턴스 만들기’로 스크립트와 모델을 고르세요." }));
    return;
  }
  for (const i of state.instances) box.append(instCard(i));
}

async function doAction(i, action, force = false) {
  if (action === "stop" && !(await confirmBox(`${i.name}을(를) 끌까요? 처리 중인 요청은 끊깁니다.`))) return;
  try {
    await api(`/api/instances/${encodeURIComponent(i.name)}/${action}${force ? "?force=true" : ""}`, { method: "POST" });
    toast({ start: "시작했습니다. 모델을 올리는 동안 ‘켜는 중’으로 보입니다.", stop: "껐습니다.", restart: "다시 시작했습니다." }[action]);
  } catch (e) {
    if (action !== "stop" && !force && e.message.includes("GPU") && !e.message.includes("포트")) {
      if (await confirmBox(`${e.message}\n\n같은 GPU를 나눠 쓰면 메모리가 모자랄 수 있습니다. 그래도 시작할까요?`)) return doAction(i, action, true);
      return;
    }
    toast(e.message, true);
  }
  refresh();
}

async function refresh() {
  try {
    state = await api("/api/state");
  } catch (e) {
    if (e.message !== "401") $("#conn").textContent = "연결 끊김";
    return;
  }
  $("#conn").textContent = `프로세스 관리: ${state.supervisor === "systemd" ? "systemd" : "프로세스 그룹"}`;
  if (tab === "dash") { drawGpus(); drawNotices(); drawInstances(); }
}

// ---- editor ----------------------------------------------------------------------------------------------------
let editing = null; // {name, isNew}
let edMode = "form";

function scriptByPath(p) { return scripts.find((s) => s.path === p); }

function fillScripts(selected) {
  const sel = $("#ed-script");
  sel.replaceChildren(...scripts.map((s) => el("option", { value: s.path, selected: s.path === selected }, s.path)));
}

function drawKnobs(script, env) {
  const box = $("#ed-knobs");
  box.replaceChildren();
  const known = new Set();
  for (const k of script ? script.knobs : []) {
    known.add(k.var);
    const input = el("input", { "data-var": k.var, value: env[k.var] ?? "", placeholder: k.default || "(비어 있음)" });
    const label = el("div", { class: "var" + (env[k.var] ? " set" : ""), text: k.var });
    input.addEventListener("input", () => label.classList.toggle("set", !!input.value));
    box.append(el("div", { class: "knob" }, label, input, k.comment ? el("div", { class: "desc", text: k.comment }) : null));
  }
  const extra = $("#ed-extra");
  extra.replaceChildren();
  for (const [k, v] of Object.entries(env)) if (!known.has(k)) addExtra(k, v);
}

function addExtra(k = "", v = "") {
  const row = el("div", { class: "extra-row" },
    el("input", { class: "ek", value: k, placeholder: "이름 (예: HF_HOME)" }),
    el("input", { class: "ev", value: v, placeholder: "값" }),
    el("button", { type: "button", class: "ghost small", onclick: () => row.remove() }, "빼기"));
  $("#ed-extra").append(row);
}
$("#ed-add-env").onclick = () => addExtra();

function formData() {
  const env = {};
  for (const i of $("#ed-knobs").querySelectorAll("input[data-var]")) if (i.value.trim() !== "") env[i.dataset.var] = i.value.trim();
  for (const r of $("#ed-extra").querySelectorAll(".extra-row")) {
    const k = $(".ek", r).value.trim(), v = $(".ev", r).value.trim();
    if (k && v) env[k] = v;
  }
  return { script: $("#ed-script").value, description: $("#ed-desc").value.trim(), env, autostart: $("#ed-autostart").checked };
}

const q = (s) => JSON.stringify(String(s));
function toYaml(d) {
  const lines = [`script: ${d.script}`];
  if (d.description) lines.push(`description: ${q(d.description)}`);
  lines.push("env:");
  const keys = Object.keys(d.env || {});
  if (!keys.length) lines[lines.length - 1] = "env: {}";
  for (const k of keys) lines.push(`  ${k}: ${q(d.env[k])}`);
  lines.push(`autostart: ${d.autostart ? "true" : "false"}`);
  return lines.join("\n") + "\n";
}

function setFormFrom(d) {
  fillScripts(d.script);
  $("#ed-desc").value = d.description || "";
  $("#ed-autostart").checked = !!d.autostart;
  const s = scriptByPath(d.script);
  $("#ed-script-title").textContent = s ? s.title : "이 스크립트를 찾지 못했습니다.";
  drawKnobs(s, Object.fromEntries(Object.entries(d.env || {}).map(([k, v]) => [k, String(v)])));
}

async function setMode(mode) {
  if (mode === edMode) return;
  if (mode === "yaml") {
    $("#ed-yaml").value = toYaml(formData());
  } else {
    try {
      const { data } = await api("/api/yaml", { method: "POST", body: { yaml: $("#ed-yaml").value } });
      setFormFrom(data);
    } catch (e) { showEdError(e.message); return; }
  }
  edMode = mode;
  for (const b of $("#editor-mode").children) b.classList.toggle("active", b.dataset.mode === mode);
  $("#ed-form-view").hidden = mode !== "form";
  $("#ed-yaml-view").hidden = mode !== "yaml";
}
$("#editor-mode").addEventListener("click", (ev) => { const b = ev.target.closest("button"); if (b) setMode(b.dataset.mode); });

function showEdError(msg) { const e = $("#ed-error"); e.hidden = !msg; e.textContent = msg || ""; }

$("#ed-script").addEventListener("change", () => {
  const d = formData();
  setFormFrom(d);
});

async function openEditor(name = null, duplicate = false) {
  scripts = await api("/api/scripts");
  showEdError("");
  edMode = "form";
  for (const b of $("#editor-mode").children) b.classList.toggle("active", b.dataset.mode === "form");
  $("#ed-form-view").hidden = false; $("#ed-yaml-view").hidden = true;
  let data = { script: scripts[0]?.path || "", description: "", env: {}, autostart: false };
  $("#ed-history").hidden = true;
  if (name) {
    const got = await api(`/api/instances/${encodeURIComponent(name)}`);
    data = got.data;
    if (!duplicate && got.versions.length) {
      $("#ed-history").hidden = false;
      $("#ed-versions").replaceChildren(...got.versions.slice(0, 30).map((v) => el("div", { class: "facts" },
        el("span", { class: "mono", text: v.id }),
        el("button", { type: "button", class: "ghost small", onclick: async () => {
          const { yaml } = await api(`/api/instances/${encodeURIComponent(name)}/versions/${encodeURIComponent(v.id)}`);
          await setMode("yaml"); $("#ed-yaml").value = yaml;
          toast("이전 판을 YAML 칸에 불러왔습니다. 저장해야 반영됩니다.");
        } }, "불러오기"))));
    }
  }
  editing = { name: duplicate ? null : name, isNew: !name || duplicate };
  $("#editor-title").textContent = editing.isNew ? (duplicate ? `${name} 복제` : "인스턴스 만들기") : `${name} 편집`;
  $("#ed-name").value = duplicate ? `${name}-copy` : (name || "");
  $("#ed-name").disabled = !editing.isNew;
  $("#ed-delete").hidden = editing.isNew;
  setFormFrom(data);
  $("#editor").showModal();
}
$("#new-instance").onclick = () => openEditor();
$("#ed-cancel").onclick = () => $("#editor").close();

$("#ed-save").onclick = async () => {
  const name = $("#ed-name").value.trim();
  const body = edMode === "yaml" ? { yaml: $("#ed-yaml").value } : { data: formData() };
  body.create = editing.isNew;
  try {
    const saved = await api(`/api/instances/${encodeURIComponent(name)}`, { method: "PUT", body });
    $("#editor").close();
    toast(saved.drift ? "저장했습니다. 돌고 있는 인스턴스는 재시작해야 반영됩니다." : "저장했습니다.");
    refresh();
  } catch (e) { showEdError(e.message); }
};

$("#ed-delete").onclick = async () => {
  if (!(await confirmBox(`${editing.name}을(를) 지울까요? 파일은 instances/.history/에 남습니다.`))) return;
  try {
    await api(`/api/instances/${encodeURIComponent(editing.name)}`, { method: "DELETE" });
    $("#editor").close(); toast("지웠습니다."); refresh();
  } catch (e) { showEdError(e.message); }
};

// ---- logs ------------------------------------------------------------------------------------------------------
let logTimer = null;
async function openLogs(name) {
  const pre = $("#logs-text");
  pre.textContent = "";
  $("#logs-title").textContent = `${name} 로그`;
  let offset = -1;
  const pull = async () => {
    try {
      const r = await api(`/api/instances/${encodeURIComponent(name)}/logs?offset=${offset}${offset < 0 ? "&limit=200000" : ""}`);
      offset = r.offset;
      if (r.text) {
        pre.textContent += r.text;
        if (pre.textContent.length > 600000) pre.textContent = pre.textContent.slice(-400000);
        if ($("#logs-follow").checked) pre.scrollTop = pre.scrollHeight;
      }
    } catch (_) {}
  };
  await pull();
  clearInterval(logTimer);
  logTimer = setInterval(pull, 1500);
  $("#logs").showModal();
}
$("#logs-close").onclick = () => $("#logs").close();
$("#logs").addEventListener("close", () => clearInterval(logTimer));

// ---- chat test -------------------------------------------------------------------------------------------------
function openChat(model) {
  const ready = state.instances.filter((i) => i.state === "ready").flatMap((i) => i.served?.length ? i.served : [i.served_name]);
  $("#chat-model").replaceChildren(...ready.map((m) => el("option", { value: m, selected: m === model }, m)));
  $("#chat-result").replaceChildren();
  $("#chat").showModal();
}
$("#chat-close").onclick = () => $("#chat").close();
$("#chat-send").onclick = async () => {
  const out = $("#chat-result");
  out.replaceChildren(el("p", { class: "muted", text: "답을 기다리는 중입니다…" }));
  $("#chat-send").disabled = true;
  try {
    const r = await api("/api/chat-test", { method: "POST", body: {
      model: $("#chat-model").value, prompt: $("#chat-prompt").value, max_tokens: Number($("#chat-max").value) } });
    out.replaceChildren(...[
      el("div", { class: "facts" },
        el("span", {}, "걸린 시간 ", el("b", { text: `${r.seconds}초` })),
        el("span", {}, "생성 토큰 ", el("b", { text: String(r.usage?.completion_tokens ?? "-") })),
        el("span", {}, "초당 토큰 ", el("b", { text: r.tokens_per_second ? String(r.tokens_per_second) : "-" })),
        el("span", {}, "인스턴스 ", el("b", { text: r.instance }))),
      r.reasoning ? el("details", {}, el("summary", { text: "생각 과정" }), el("div", { class: "chat-out", text: r.reasoning })) : null,
      el("div", { class: "chat-out", text: r.content || "(빈 답)" })].filter(Boolean));
  } catch (e) {
    out.replaceChildren(el("p", { class: "error", text: e.message }));
  } finally { $("#chat-send").disabled = false; }
};

// ---- engine environments ---------------------------------------------------------------------------------------
let jobTimer = null;
async function loadEnvs() {
  let r;
  try { r = await api("/api/envs"); } catch (e) { return; }
  $("#envs-dir").textContent = `위치: ${r.dir}`;
  const box = $("#envs");
  box.replaceChildren();
  if (!r.envs.length) box.append(el("div", { class: "card empty", text: "아직 설치한 엔진 환경이 없습니다. 아래에서 설치하거나 서버에서 envs/install-engine.sh를 실행하세요." }));
  for (const e of r.envs) {
    const engines = Object.entries(e.engines).map(([k, v]) => `${k} ${v}`).join(", ") || "엔진 없음";
    box.append(el("div", { class: "card" },
      el("div", { class: "inst-head" }, el("span", { class: "inst-name", text: e.name }), el("span", { class: "muted", text: engines }),
        e.lock ? null : el("span", { class: "badge", text: "lock.txt 없음" })),
      el("div", { class: "kv", style: "margin-top:8px" }, Object.entries(e.bins).flatMap(([k, v]) => [
        el("span", { class: "mono small", text: k }),
        el("div", { class: "facts" }, el("code", { text: v }),
          el("button", { class: "ghost small", onclick: () => { navigator.clipboard?.writeText(v); toast("복사했습니다. 인스턴스 편집에서 이 칸에 붙여 넣으세요."); } }, "복사"))]))));
  }
  const jobs = $("#jobs");
  jobs.replaceChildren(...r.jobs.slice(0, 5).map((j) => el("div", { class: "card job", "data-job": j.id },
    el("div", { class: "inst-head" }, el("strong", { text: j.title }),
      el("span", { class: `pill ${j.state === "running" ? "starting" : j.state === "done" ? "ready" : "failed"}`,
        text: j.state === "running" ? "설치 중" : j.state === "done" ? "끝남" : `실패 (코드 ${j.code})` })),
    el("pre", { class: "tail", text: "" }))));
  for (const j of r.jobs.slice(0, 5)) pullJob(j.id);
  clearInterval(jobTimer);
  if (r.jobs.some((j) => j.state === "running")) jobTimer = setInterval(() => { if (tab === "envs") loadEnvs(); }, 3000);
}
async function pullJob(id) {
  try {
    const j = await api(`/api/jobs/${id}`);
    const pre = document.querySelector(`[data-job="${id}"] pre`);
    if (pre) { pre.textContent = j.text.split("\n").slice(-60).join("\n"); pre.scrollTop = pre.scrollHeight; }
  } catch (_) {}
}
$("#install-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    await api("/api/envs/install", { method: "POST", body: { engine: $("#install-engine").value, version: $("#install-version").value } });
    toast("설치를 시작했습니다. vLLM은 수 GB를 받아 몇 분 걸립니다.");
    loadEnvs();
  } catch (e) { toast(e.message, true); }
});

// ---- connection info -------------------------------------------------------------------------------------------
function drawConnect() {
  const base = `${location.protocol}//${location.host}/v1`;
  const ready = state ? state.instances.filter((i) => i.state === "ready").map((i) => i.served_name) : [];
  const model = ready[0] || "모델-이름";
  const aliases = state ? Object.entries(state.gateway.aliases || {}) : [];
  const key = state?.gateway.key_required ? "<gateway_key>" : "EMPTY";
  $("#connect").replaceChildren(el("div", { class: "kv" },
    el("span", { text: "게이트웨이 주소" }), el("pre", { text: base }),
    el("span", { text: "지금 쓸 수 있는 모델" }), el("pre", { text: ready.join("\n") || "(준비된 인스턴스가 없습니다)" }),
    el("span", { text: "별칭" }), el("pre", { text: aliases.map(([a, t]) => `${a} → ${t}`).join("\n") || "없음 (control/config.yaml의 aliases에 default: <서빙 이름> 처럼 적으면 생깁니다)" }),
    el("span", { text: "curl" }), el("pre", { text: `curl ${base}/chat/completions -H 'Content-Type: application/json' \\\n  -H 'Authorization: Bearer ${key}' \\\n  -d '{"model": "${model}", "messages": [{"role": "user", "content": "hello"}]}'` }),
    el("span", { text: "Python (openai)" }), el("pre", { text: `from openai import OpenAI\nclient = OpenAI(base_url="${base}", api_key="${key}")\nr = client.chat.completions.create(model="${model}", messages=[{"role": "user", "content": "hello"}])\nprint(r.choices[0].message.content)` }),
    el("span", { text: "Codex CLI" }), el("pre", { text: `# ~/.codex/config.toml\n[model_providers.local]\nname = "local"\nbase_url = "${base}"\nwire_api = "chat"\n\n[profiles.local]\nmodel_provider = "local"\nmodel = "${model}"` })));
}

// ---- start -----------------------------------------------------------------------------------------------------
let timer = null;
async function start() {
  try { state = await api("/api/state"); } catch (e) { if (e.message !== "401") showLogin(`관리판에 연결하지 못했습니다: ${e.message}`); return; }
  $("#login").hidden = true; $("#app").hidden = false;
  refresh();
  clearInterval(timer);
  timer = setInterval(refresh, 2000);
}
if (token) start(); else showLogin();
