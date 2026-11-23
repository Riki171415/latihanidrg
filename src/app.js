"use strict";
const bank = JSON.parse(document.getElementById("case-data").textContent);
const $ = id => document.getElementById(id);
const contentRevision = "2026-11-23.3";
const storageKey = "latihan-koding-idrg-ics-2026-v1";
const modules = [
  {id:"2-casemix", name:"Casemix · Materi 2", title:"Grouper, validasi, dan isian episode"},
  {id:"2-coding", name:"Pengodean iDRG · Materi 2", title:"Aturan morbiditas dan konvensi pengodean"},
  {id:"4", name:"Materi 4", title:"Pre-MDC dan MDC 10–20"},
  {id:"6", name:"Materi 6", title:"MDC 21–90"}
];
const moduleCases = id => bank.filter(c => String(c.module) === id);
const casemixIds = new Set(["M2-01", "M2-02"]);
const availableCases = id => {
  if (id === "2-casemix") return bank.filter(c => casemixIds.has(c.id));
  if (id === "2-coding") return moduleCases("2").filter(c => !casemixIds.has(c.id));
  return moduleCases(id);
};
const moduleInfo = id => modules.find(m => m.id === id);
const letter = i => "ABCDE"[i];
const make = (tag, content, className) => {
  const element = document.createElement(tag);
  if (content !== undefined) element.textContent = content;
  if (className) element.className = className;
  return element;
};
const loadProfiles = () => {
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey));
    if (saved?.format === 4 && Array.isArray(saved.profiles)) return saved.profiles;
    if (saved?.format === 3 && Array.isArray(saved.profiles)) {
      saved.profiles.forEach(splitMaterialTwo);
      return saved.profiles;
    }
    if (saved && typeof saved.name === "string" && ["all", "2", "4", "6"].includes(saved.selection) && saved.answers) {
      const entries = saved.selection === "all" ? bank : moduleCases(saved.selection);
      if (saved.format !== 2) migrateAnswers(saved, entries);
      const profile = {name:saved.name, materials:{}};
      for (const id of ["2","4","6"]) {
        if (saved.selection !== "all" && saved.selection !== id) continue;
        const byModule = moduleCases(id);
        const prefix = "M" + id + "-";
        const answers = Object.fromEntries(Object.entries(saved.answers).filter(([key]) => key.startsWith(prefix)));
        const index = Math.max(0, byModule.indexOf(entries[saved.index]));
        if (saved.finished || Object.keys(answers).length || index > 0 || saved.selection === id) {
          profile.materials[id] = {index, answers, finished:!!saved.finished};
        }
      }
      splitMaterialTwo(profile);
      return [profile];
    }
  } catch {}
  return [];
};
function splitMaterialTwo(profile) {
  const legacy = profile.materials["2"];
  if (!legacy) return;
  const originalCase = moduleCases("2")[legacy.index];
  for (const id of ["2-casemix","2-coding"]) {
    const entries = availableCases(id);
    const ids = new Set(entries.map(entry => entry.id));
    const answers = Object.fromEntries(Object.entries(legacy.answers).filter(([key]) => ids.has(key.slice(0,-2))));
    if (legacy.finished || Object.keys(answers).length || entries.includes(originalCase)) {
      profile.materials[id] = {answers, finished:legacy.finished, index:Math.max(0,entries.indexOf(originalCase))};
    }
  }
  delete profile.materials["2"];
}
const profiles = loadProfiles();
let profile = null;
let activeModule = null;
let session = null;
let wrongOnly = false;
const cases = () => availableCases(activeModule);
const keyFor = (c, i) => c.id + "-" + i;
const hasAnswer = value => value !== undefined && String(value).trim() !== "";
function save() {
  try {
    localStorage.setItem(storageKey, JSON.stringify({format:4,profiles}));
    $("save-state").textContent = "Progres tersimpan di browser ini";
  } catch {
    $("save-state").textContent = "Penyimpanan tidak tersedia. Cetak hasil sebelum menutup.";
  }
}
function screen(which) {
  for (const id of ["start", "recap", "practice", "result", "all-results", "guide"]) $(id).hidden = id !== which;
  document.querySelectorAll(".nav-item").forEach(button => {
    button.classList.toggle("active", button.dataset.screen === which ||
      (button.dataset.screen === "recap" && which === "practice") ||
      (button.dataset.screen === "all-results" && which === "result"));
  });
  $("sidebar-name").textContent = profile?.name ?? "Peserta pelatihan";
  $("avatar").textContent = profile?.name.trim().split(/\s+/).map(word => word[0]).slice(0,2).join("").toUpperCase() ?? "P";
  document.body.dataset.screen = which;
  window.scrollTo(0, 0);
}
function startPage() {
  screen("start");
}
function position() {
  session.index = Math.min(Math.max(0, Number(session.index) || 0), cases().length - 1);
  return session.index;
}
function updateProgress() {
  const all = cases();
  let count = 0;
  all.forEach((c, i) => {
    const done = c.items.filter((item, j) => hasAnswer(session.answers[keyFor(c, j)])).length;
    count += done;
    const b = $("nav-" + c.id);
    b.classList.toggle("done", done === c.items.length);
    b.setAttribute("aria-label", "Kasus " + (i + 1) + ", " + done + " dari 4 butir terisi");
  });
  const total = all.length * 4;
  $("progress-text").textContent = count + " dari " + total + " butir terisi";
  $("progress-fill").style.width = (100 * count / total) + "%";
  return total - count;
}
function go(index, question = 0) {
  session.index = index;
  session.question = question;
  save();
  renderCase(true);
  window.scrollTo(0, 0);
}
function renderCase(focus = false) {
  const pos = position();
  const all = cases();
  const c = all[pos];
  $("student-label").textContent = profile.name + " · " + moduleInfo(activeModule).name;
  $("case-module").textContent = c.id + " · Kasus " + (pos + 1) + " dari " + all.length;
  $("case-title").textContent = c.title;
  $("case-selector").replaceChildren();
  all.forEach((entry, i) => {
    const b = make("button", i + 1, "case-button");
    b.type = "button";
    b.id = "nav-" + entry.id;
    b.setAttribute("aria-current", i === pos);
    b.addEventListener("click", () => go(i));
    $("case-selector").append(b);
  });
  $("record-body").replaceChildren();
  $("case-pdf").dataset.src = c.pdf;
  if (!$("case-pdf").hidden) renderCasePdf(c.pdf);
  else {
    pdfRequest++;
    $("case-pdf").replaceChildren();
  }
  $("pdf-filename").textContent = c.id + ".pdf";
  $("pdf-open").href = c.pdf;
  $("pdf-download").href = c.pdf;
  $("pdf-download").download = c.id + "_Berkas_Latihan.pdf";
  $("case-pdf").setAttribute("aria-label","Berkas kasus " + c.id + " — " + c.title);
  c.records.forEach(([label, body]) => {
    const p = make("p");
    p.append(make("span", label, "part"), document.createTextNode(body));
    $("record-body").append(p);
  });
  renderQuestion(false);
  updateProgress();
  if (focus) $("case-title").focus({preventScroll:true});
}
function renderQuestion(focus = false) {
  const c = cases()[position()];
  const i = session.question = Math.min(Math.max(0, Number(session.question) || 0), c.items.length - 1);
  const item = c.items[i];
  const id = keyFor(c, i);
  $("question-position").textContent = "SOAL " + (i + 1) + " DARI " + c.items.length;
  $("questions").replaceChildren();
  $("question-selector").replaceChildren();
  const updateState = () => {
    const answered = hasAnswer(session.answers[id]);
    $("answer-state").textContent = answered ? "Jawaban tersimpan" : "Belum dijawab";
    $("answer-state").classList.toggle("answered", answered);
    $("question-selector").querySelectorAll("button").forEach((b, n) => b.classList.toggle("done", hasAnswer(session.answers[keyFor(c,n)])));
  };
  c.items.forEach((_, n) => {
    const b = make("button", "Soal " + (n + 1));
    b.type = "button";
    b.setAttribute("aria-current", n === i ? "step" : "false");
    b.addEventListener("click", () => {session.question = n; save(); renderQuestion(true);});
    $("question-selector").append(b);
  });
  const fieldset = make("fieldset");
  const legend = make("legend", item.prompt);
  legend.id = "label-" + id;
  legend.tabIndex = -1;
  fieldset.append(legend);
  const group = make("div", undefined, "answers");
  item.options.forEach((option, j) => {
    const label = make("label", undefined, "option");
    const input = make("input");
    input.type = "radio";
    input.name = id;
    input.value = String(j);
    input.checked = session.answers[id] === String(j);
    input.addEventListener("change", () => {
      session.answers[id] = input.value;
      session.answerLabels ??= {};
      session.answerLabels[id] = option;
      save();
      updateProgress();
      updateState();
      group.querySelector(".hint")?.remove();
    });
    label.append(input, make("span", letter(j), "option-letter"), make("span", option));
    group.append(label);
  });
  if (session.answers[id]?.startsWith("lama:")) group.append(make("p", "Jawaban versi sebelumnya: " + session.answers[id].slice(5), "hint"));
  fieldset.append(group);
  $("questions").append(fieldset);
  $("prev").disabled = position() === 0 && i === 0;
  $("next").disabled = position() === cases().length - 1 && i === c.items.length - 1;
  $("next").textContent = i === c.items.length - 1 ? "Kasus berikutnya →" : "Soal berikutnya →";
  updateState();
  if (focus) {
    legend.focus({preventScroll:true});
    if (window.matchMedia("(max-width:740px)").matches) $("question-position").scrollIntoView({block:"start"});
  }
}
function moveQuestion(delta) {
  const next = (Number(session.question) || 0) + delta;
  if (next < 0) return go(position() - 1, 3);
  if (next > 3) return go(position() + 1, 0);
  session.question = next;
  save();
  renderQuestion(true);

}
function normalizeCode(value) {
  return value.toUpperCase().replace(/[.\-†*]/g, "");
}
function codeParts(value) {
  const clean = String(value).toUpperCase().trim().replace(/\s*\.\s*/g, ".");
  return clean.split(/[,;\/|\s]+/).filter(Boolean).map(normalizeCode);
}
function sameCodes(response, codes, ordered) {
  const given = codeParts(response);
  const expected = codes.map(normalizeCode);
  if (!ordered) { given.sort(); expected.sort(); }
  return given.length === expected.length && given.every((value, i) => value === expected[i]);
}
function migrateAnswers(saved, entries) {
  for (const c of entries) {
    c.items.forEach((item, i) => {
      const key = c.id + "-" + i;
      const old = saved.answers[key];
      if (old === undefined || String(old).trim() === "") return;
      let match;
      if (item.legacyOptions) {
        match = item.options.indexOf(item.legacyOptions[Number(old)]);
      } else {
        match = item.options.findIndex((option, index) => sameCodes(
          old, item.choiceCodes?.[index] ?? codeParts(option), item.ordered
        ));
      }
      saved.answers[key] = match < 0 ? "lama:" + old : String(match);
    });
  }
  saved.format = 2;
}
function reviewFor(activeCases, responses) {
  return activeCases.map(c => ({
    case: c,
    items: c.items.map((item, i) => {
      const response = responses[keyFor(c, i)];
      const answered = hasAnswer(response);
      return { item, response, answered, correct: String(item.correct) === response };
    })
  }));
}
const scoreNumber = new Intl.NumberFormat("id-ID", {maximumFractionDigits:1});
const grade = (right, total) => scoreNumber.format(right * 100 / total);
function summarize(review) {
  const all = review.flatMap(c => c.items);
  const right = all.filter(i => i.correct).length;
  const answered = all.filter(i => i.answered).length;
  return {right, answered, total:all.length, wrong:answered - right, missing:all.length - answered};
}
function openModule(id) {
  activeModule = id;
  session = profile.materials[id] ??= {index:0, question:0, answers:{}, answerLabels:{}, finished:false, contentRevision};
  // Preserve the text of existing answers when the editorial revision changes choices.
  if (session.contentRevision !== contentRevision) {
    const priorRevision = session.contentRevision;
    session.answerLabels ??= {};
    availableCases(id).forEach(c => c.items.forEach((q, i) => {
      const key = keyFor(c,i), response = session.answers[key];
      const previousOptions = priorRevision === "2026-11-23.2"
        ? q.previousRevisionOptions ?? q.options : q.previousOptions ?? q.options;
      if (hasAnswer(response) && !response.startsWith("lama:")) session.answerLabels[key] ??= previousOptions[Number(response)];
    }));
    session.contentRevision = contentRevision;
  }
  save();
  if (session.finished) {
    wrongOnly = false;
    renderResult();
  } else {
    screen("practice");
    renderCase(true);
  }
}
function renderRecap() {
  screen("recap");
  $("recap-student").textContent = profile.name;
  const list = $("recap-modules");
  list.replaceChildren();
  $("recap-casemix").replaceChildren();
  let submitted = 0;
  let totalRight = 0;
  let totalGraded = 0;
  for (const {id, name, title} of modules) {
    const attempt = profile.materials[id];
    const entries = availableCases(id);
    const stats = summarize(reviewFor(entries, attempt?.answers ?? {}));
    if (attempt?.finished) {
      submitted++;
      totalRight += stats.right;
      totalGraded += stats.total;
    }
    const card = make("article", undefined, "card");
    card.append(make("span", id === "2-casemix" ? "CASEMIX / 01" : "PENGODEAN / " + (modules.findIndex(m => m.id === id) + 1).toString().padStart(2,"0"), "packet-label"));
    card.dataset.material = id;
    const status = attempt?.finished
      ? "Dikirim · " + stats.right + "/" + stats.total + " benar"
      : attempt ? "Draf · " + stats.answered + "/" + stats.total + " terisi" : "Belum dimulai · " + stats.total + " butir";
    const action = make("button", attempt?.finished ? "Lihat nilai" : attempt ? "Lanjutkan" : "Mulai", attempt?.finished ? "secondary" : "");
    action.type = "button";
    action.setAttribute("aria-label", action.textContent + " " + name);
    action.addEventListener("click", () => openModule(id));
    card.append(
      make("h3", name),
      make("p", title, "small muted"),
      make("p", status, "module-summary small"),
      make("p", attempt?.finished ? grade(stats.right, stats.total) + " / 100" : entries.length + " kasus · " + stats.total + " soal", attempt?.finished ? "module-score graded" : "module-score"),
      action
    );
    (id === "2-casemix" ? $("recap-casemix") : list).append(card);
  }
  $("recap-total").textContent = totalGraded ? grade(totalRight,totalGraded) + " / 100" : "—";
  $("recap-detail").textContent = submitted
    ? submitted + " dari " + modules.length + " paket dikirim · " + totalRight + " dari " + totalGraded + " butir benar"
    : "Nilai dihitung dari jawaban pada paket yang sudah dikirim.";
  renderScores();
  $("recap-title").focus({preventScroll:true});
}
function renderScores() {
  $("recap-name").textContent = profile.name;
  $("score-table").replaceChildren();
  let submitted = 0;
  let right = 0;
  let total = 0;
  for (const packet of modules) {
    const attempt = profile.materials[packet.id];
    const stats = summarize(reviewFor(availableCases(packet.id), attempt?.answers ?? {}));
    if (attempt?.finished) { submitted++; right += stats.right; total += stats.total; }
    const row = make("tr");
    row.append(make("td",packet.name));
    const status = make("td");
    status.append(make("span",attempt?.finished ? "Selesai" : attempt ? "Draf" : "Belum dikerjakan",
      attempt?.finished ? "status-tag done" : "status-tag"));
    row.append(status,make("td",attempt?.finished ? stats.right + " / " + stats.total : "—"));
    const score = make("td");
    score.append(make("strong",attempt?.finished ? grade(stats.right,stats.total) : "—"));
    const actionCell = make("td");
    const button = make("button",attempt?.finished ? "Lihat hasil" : attempt ? "Lanjutkan" : "Kerjakan","secondary");
    button.addEventListener("click",() => openModule(packet.id));
    actionCell.append(button);
    row.append(score,actionCell);
    $("score-table").append(row);
  }
  $("completion-summary").textContent = submitted + " dari " + modules.length + " paket selesai";
  $("recap-total").textContent = total ? grade(right,total) : "—";
  $("recap-detail").textContent = total ? right + " dari " + total + " butir benar" : "Kirim satu paket untuk melihat nilai.";
}
function showAllResults() {
  renderScores();
  screen("all-results");
  $("recap-table-title").focus({preventScroll:true});
}
function renderResult(focus = true) {
  screen("result");
  const review = reviewFor(cases(), session.answers);
  const {right, total, wrong, missing} = summarize(review);
  $("result-title").textContent = "Nilai " + moduleInfo(activeModule).name;
  $("result-student").textContent = profile.name + " · " + moduleInfo(activeModule).title;
  $("score").replaceChildren(document.createTextNode(grade(right, total)), make("small", " / 100"));
  $("result-key").replaceChildren();
  [[right + " / " + total, "Benar"], [wrong, "Salah"], [missing, "Kosong"]].forEach(([value, name]) => {
    const box = make("div", undefined, "card");
    box.append(make("strong", value), make("span", name, "small muted"));
    $("result-key").append(box);
  });
  $("filter-review").setAttribute("aria-pressed", wrongOnly);
  $("filter-review").textContent = wrongOnly ? "Tampilkan semua pembahasan" : "Tampilkan yang perlu ditinjau";
  $("review").replaceChildren();
  review.forEach(({case: c, items}) => {
    const correct = items.filter(i => i.correct).length;
    if (wrongOnly && correct === items.length) return;
    const details = make("details", undefined, "review-case");
    const summary = make("summary", c.id + " · " + c.title);
    summary.append(make("span", correct + " / 4"));
    details.append(summary);
    items.forEach(({item, response, answered, correct: ok}, i) => {
      if (wrongOnly && ok) return;
      const panel = make("div", undefined, "check-item");
      const selectedLabel = session.answerLabels?.[keyFor(c,i)] ?? item.options[Number(response)];
      const value = !answered ? "Belum dijawab" : response.startsWith("lama:")
        ? response.slice(5) : letter(Number(response)) + ". " + selectedLabel;
      panel.append(make("h3", (i+1) + ". " + item.prompt));
      panel.append(make("p", (ok ? "Benar" : answered ? "Salah" : "Kosong") + " · " + value, ok ? "correct small" : "incorrect small"));
      panel.append(make("p", "Kunci " + letter(item.correct) + ". " + item.options[item.correct], "small"));
      panel.append(make("p", item.feedback));
      details.append(panel);
    });
    if (c.reference) details.append(make("p", c.reference, "muted small"));
    $("review").append(details);
  });
  if (!$("review").childElementCount) $("review").append(make("p", "Semua jawaban benar."));
  if (focus) $("result-title").focus({preventScroll:true});
}
$("setup").addEventListener("submit", event => {
  event.preventDefault();
  const name = $("participant").value.trim().replace(/\s+/g, " ");
  if (!name) { $("participant").focus(); return; }
  profile = profiles.find(entry => entry.name.toLowerCase().replace(/\s+/g, " ").trim() === name.toLowerCase());
  if (!profile) {
    profile = {name, materials:{}};
    profiles.push(profile);
  }
  save();
  renderRecap();
});
$("pause").addEventListener("click", renderRecap);
$("switch-participant").addEventListener("click", () => {
  $("participant").value = "";
  startPage();
  $("participant").focus();
});
$("mobile-participant").addEventListener("click",() => $("switch-participant").click());
$("prev").addEventListener("click", () => moveQuestion(-1));
$("next").addEventListener("click", () => moveQuestion(1));
$("submit-answers").addEventListener("click", () => {
  const missing = updateProgress();
  $("submit-message").textContent = missing
    ? "Paket ini masih memiliki " + missing + " butir kosong. Butir kosong bernilai 0 setelah dikirim."
    : "Semua butir sudah terisi. Setelah paket dikirim, nilai dan pembahasan akan tampil.";
  $("confirm-submit").showModal();
});
$("check-again").addEventListener("click", () => $("confirm-submit").close());
$("finish").addEventListener("click", () => {
  $("confirm-submit").close();
  session.finished = true;
  session.submittedAt = new Date().toISOString();
  wrongOnly = false;
  save();
  renderResult();
});
$("restart").addEventListener("click", showAllResults);
$("filter-review").addEventListener("click", () => { wrongOnly = !wrongOnly; renderResult(false); });
$("print-result").addEventListener("click", () => window.print());
$("print-recap").addEventListener("click", () => window.print());
$("back-packages").addEventListener("click",renderRecap);
$("open-recap").addEventListener("click",showAllResults);
$("brand-home").addEventListener("click",event => {
  event.preventDefault();
  profile ? renderRecap() : startPage();
});
document.querySelectorAll(".nav-item").forEach(button => {
  button.addEventListener("click",() => {
    if (button.dataset.screen === "guide") return screen("guide");
    if (!profile) return startPage();
    button.dataset.screen === "all-results" ? showAllResults() : renderRecap();
  });
});
function showDocument(mode) {
  const pdf = mode === "pdf";
  $("case-pdf").hidden = !pdf;
  $("record-body").hidden = pdf;
  $("pdf-zoom").hidden = !pdf;
  $("view-pdf").setAttribute("aria-pressed",pdf);
  $("view-text").setAttribute("aria-pressed",!pdf);
  if (pdf && !$("case-pdf").querySelector("canvas")) renderCasePdf(cases()[position()].pdf);
}
let pdfViewer = null;
let pdfRequest = 0;
let pdfZoom = 1;
async function renderCasePdf(url) {
  const request = ++pdfRequest;
  $("case-pdf").setAttribute("aria-busy", "true");
  try {
    pdfViewer ??= import("./pdf-viewer.js");
    const viewer = await pdfViewer;
    if (request !== pdfRequest) return;
    await viewer.renderPdf(url,$("case-pdf"),pdfZoom);
  } catch {
    if (request !== pdfRequest) return;
    $("case-pdf").replaceChildren(make("p","PDF belum dapat dimuat. Gunakan Buka atau Unduh pada bilah berkas.","pdf-status"));
    $("case-pdf").setAttribute("aria-busy", "false");
  }
}
$("view-pdf").addEventListener("click",() => showDocument("pdf"));
$("view-text").addEventListener("click",() => showDocument("text"));
function changeZoom(delta) {
  pdfZoom = Math.round(Math.min(2, Math.max(1, pdfZoom + delta)) * 100) / 100;
  $("zoom-value").textContent = Math.round(pdfZoom * 100) + "%";
  $("zoom-out").disabled = pdfZoom === 1;
  $("zoom-in").disabled = pdfZoom === 2;
  renderCasePdf(cases()[position()].pdf);
}
$("zoom-out").disabled = true;
$("zoom-out").addEventListener("click", () => changeZoom(-.25));
$("zoom-in").addEventListener("click", () => changeZoom(.25));
$("download-csv").addEventListener("click",() => {
  const escape = value => '"' + String(value).replace(/^[=+@-]/,"'$&").replaceAll('"','""') + '"';
  const rows = [["Nama peserta","Paket","Status","Benar","Jumlah butir","Nilai","Dikirim pada"]];
  for (const packet of modules) {
    const attempt = profile.materials[packet.id];
    const stats = summarize(reviewFor(availableCases(packet.id), attempt?.answers ?? {}));
    rows.push([profile.name,packet.name,attempt?.finished ? "Selesai" : attempt ? "Draf" : "Belum dikerjakan",
      attempt?.finished ? stats.right : "",stats.total,attempt?.finished ? grade(stats.right,stats.total) : "",
      attempt?.submittedAt ? new Date(attempt.submittedAt).toLocaleString("id-ID") : ""]);
  }
  const url = URL.createObjectURL(new Blob(["\ufeff" + rows.map(row => row.map(escape).join(";")).join("\r\n")],{type:"text/csv;charset=utf-8"}));
  const link = make("a");
  link.href = url;
  link.download = "Rekap_iDRG_" + profile.name.replace(/[^\p{L}\p{N}]+/gu,"_") + ".csv";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url),1000);
});
startPage();
