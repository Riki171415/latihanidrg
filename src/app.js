"use strict";
const bank = JSON.parse(document.getElementById("case-data").textContent);
const bankRevision = bank[0].contentRevision;
const bankCache = new Map([[bankRevision,bank]]);
async function bankForRevision(revision) {
  if(bankCache.has(revision))return bankCache.get(revision);
  if(!/^\d{4}-\d{2}-\d{2}\.\d+$/.test(revision))throw new Error("Versi soal tidak dikenal.");
  const response=await fetch("banks/"+revision+".json");
  if(!response.ok)throw new Error("Berkas soal versi sebelumnya belum dapat dimuat. Coba kembali.");
  const entries=await response.json();
  if(!Array.isArray(entries)||entries.length!==28||entries.some(c=>c.contentRevision!==revision))throw new Error("Versi berkas soal tidak sesuai.");
  bankCache.set(revision,entries);return entries;
}
const $ = id => document.getElementById(id);
const modules = [
  {id:"2-casemix", name:"Casemix · Materi 2", title:"Grouper, validasi, dan isian episode"},
  {id:"2-coding", name:"Pengodean iDRG · Materi 3", title:"Aturan morbiditas dan konvensi pengodean"},
  {id:"4", name:"Materi 4", title:"Pre-MDC dan MDC 10–20"},
  {id:"6", name:"Materi 6", title:"MDC 21–90"}
];
const moduleCases = id => bank.filter(c => String(c.module) === id);
const casemixIds = new Set(["M2-01", "M2-02"]);
const availableCases = (id, entries=bank) => {
  if (id === "2-casemix") return entries.filter(c => casemixIds.has(c.id));
  if (id === "2-coding") return entries.filter(c=>String(c.module)==="2"&&!casemixIds.has(c.id));
  return entries.filter(c=>String(c.module)===id);
};
const moduleInfo = id => modules.find(m => m.id === id);
const letter = i => "ABCDE"[i];
const make = (tag, content, className) => {
  const element = document.createElement(tag);
  if (content !== undefined) element.textContent = content;
  if (className) element.className = className;
  return element;
};
const cloud = IDRGCloud;
let identity = null, isAdmin = false, saveTimer = null, restoring = null, recovering = false;
let saveQueue = Promise.resolve();
let authEpoch=0,moduleRequest=0;
let profile = null;
let activeModule = null;
let session = null;
let wrongOnly = false;
const cases = () => availableCases(activeModule,session?.caseBank??bank);
const keyFor = (c, i) => c.id + "-" + i;
const correctionFor=(revision,itemId)=>["2026-11-23.3","2026-11-23.4"].includes(revision)&&itemId==="M6-05-2"
  ? "Koreksi materi: kode ORIF humerus adalah 79.31, sehingga pasangan tindakan yang benar ialah WSD 34.04 dan ORIF 79.31. Nilai yang tercatat di bawah berasal dari kunci versi saat pengerjaan."
  : null;
const hasAnswer = value => value !== undefined && String(value).trim() !== "";
function notify(message, retry = false) {
  $("global-message").hidden = !message;
  $("global-message").querySelector("span").textContent = message;
  $("retry-save").hidden = !retry;
}
function draftKey(attempt) { return "idrg-account-draft:" + identity.id + ":" + attempt.id; }
function cacheDraft(attempt) {
  try { localStorage.setItem(draftKey(attempt),JSON.stringify({answers:attempt.answers,index:attempt.index,question:attempt.question,version:attempt.version,dirty:!!attempt.dirty})); } catch {}
}
function savePosition() {
  if (!identity || !session?.id || session.finished) return;
  cacheDraft(session);
}
function save() {
  if (!identity || !session?.id || session.finished) return;
  session.dirty = true;
  cacheDraft(session);
  $("save-state").textContent = "Menyimpan jawaban…";
  clearTimeout(saveTimer);
  const attempt = session;
  saveTimer = setTimeout(() => queueSave(attempt).catch(error => notify(cloud.friendly(error),true)),2500);
}
function queueSave(attempt) {
  const task = saveQueue.catch(() => {}).then(async () => {
    if (!attempt?.dirty || attempt.finished) return;
    const snapshot = {answers:{...attempt.answers},index:attempt.index,question:attempt.question};
    try {
      const row = await cloud.rpc("idrg_save_attempt",{p_id:attempt.id,p_answers:snapshot.answers,p_case_index:snapshot.index||0,p_question_index:snapshot.question||0,p_version:attempt.version});
      attempt.version = row.version;
      attempt.dirty = JSON.stringify(snapshot.answers)!==JSON.stringify(attempt.answers)||snapshot.index!==attempt.index||snapshot.question!==attempt.question;
      if (attempt.dirty) cacheDraft(attempt);
      else {try {localStorage.removeItem(draftKey(attempt));} catch {}}
      $("save-state").textContent = attempt.dirty ? "Menyimpan perubahan…" : "Tersimpan di akun Anda";
      notify("");
    } catch (error) {
      $("save-state").textContent = "Belum tersimpan ke server";
      throw error;
    }
  });
  saveQueue = task;
  return task;
}
async function flushSave() {
  clearTimeout(saveTimer);
  await queueSave(session);
}
function releasePdfContainer() {
  pdfRequest++;
  const container = $("case-pdf");
  if (pdfViewer) {
    pdfViewer.then(v => v.clearPdf(container)).catch(() => {});
  } else {
    container.querySelectorAll("canvas").forEach(c => { c.width = 0; c.height = 0; });
    container.replaceChildren();
    container.setAttribute("aria-busy", "false");
  }
}
function screen(which) {
  if (which !== "practice") releasePdfContainer();
  if (!profile && !["start","guide"].includes(which)) which="start";
  if (["admin","admin-detail"].includes(which) && !isAdmin) which=profile?"recap":"start";
  if (profile && !profile.complete && !["start","account","guide"].includes(which)) which="account";
  for (const id of ["start", "recap", "practice", "result", "all-results", "guide", "account", "admin", "admin-detail"]) $(id).hidden = id !== which;
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
  savePosition();
  renderCase(true);
  window.scrollTo(0, 0);
}
function renderCase(focus = false) {
  const pos = position();
  const all = cases();
  const c = all[pos];
  $("student-label").textContent = profile.name + " · " + moduleInfo(activeModule).name;
  $("case-module").textContent = (c.displayId??c.id) + " · Kasus " + (pos + 1) + " dari " + all.length + " · Versi " + c.contentRevision;
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
  else releasePdfContainer();
  $("pdf-filename").textContent = (c.displayId??c.id) + ".pdf";
  $("pdf-open").href = c.pdf;
  $("case-pdf").setAttribute("aria-label","Berkas kasus " + (c.displayId??c.id) + " — " + c.title);
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
    $("answer-state").textContent = answered ? "Jawaban dipilih" : "Belum dijawab";
    $("answer-state").classList.toggle("answered", answered);
    $("question-selector").querySelectorAll("button").forEach((b, n) => b.classList.toggle("done", hasAnswer(session.answers[keyFor(c,n)])));
  };
  c.items.forEach((_, n) => {
    const b = make("button", "Soal " + (n + 1));
    b.type = "button";
    b.setAttribute("aria-current", n === i ? "step" : "false");
    b.addEventListener("click", () => {session.question = n; savePosition(); renderQuestion(true);});
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
  savePosition();
  renderQuestion(true);

}
function reviewFor(activeCases, responses, reviewItems = {}) {
  return activeCases.map(c => ({
    case: c,
    items: c.items.map((original, i) => {
      const item=reviewItems[keyFor(c,i)] ?? original;
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
async function openModule(id, previousAttempt=null) {
  const request=++moduleRequest, owner=identity?.id;
  if (!profile?.complete) return openAccount();
  try {
    await flushSave();
    const existing=previousAttempt??(profile.materials[id]?.revision===bankRevision?profile.materials[id]:null);
    const row = existing ? null : await cloud.rpc("idrg_start_packet_versioned",{p_packet_id:id,p_revision:bankRevision});
    const nextSession=existing??cloud.attemptFromRow(row);
    const caseBank=nextSession.caseBank??await bankForRevision(nextSession.revision);
    if(request!==moduleRequest||identity?.id!==owner)return;
    activeModule = id;
    session = nextSession;
    session.caseBank=caseBank;
    try {
      const cached = JSON.parse(localStorage.getItem(draftKey(session)));
      const answersDiffer = !!cached && JSON.stringify(cached.answers)!==JSON.stringify(session.answers);
      if (!session.finished && cached && cached.version===session.version) {
        session.index=cached.index;session.question=cached.question;
        if (cached.dirty || answersDiffer) {
          session.answers=cached.answers;session.dirty=true;
          notify("Jawaban yang belum terkirim dipulihkan. Menyimpan kembali…",true);
        }
      } else if(cached && cached.version!==session.version && (cached.dirty || answersDiffer)) notify("Ada perubahan dari perangkat lain. Data terbaru dari server digunakan.");
    } catch {}
    if(session.revision===bankRevision)profile.materials[id] = session;
    if (session.finished) {
      await loadReview(session);
      if(request!==moduleRequest||identity?.id!==owner)return;
      wrongOnly = false;
      renderResult();
    } else {screen("practice");renderCase(true);if(session.dirty)save();}
  } catch(error) {notify(cloud.friendly(error),!!session?.dirty);}
}
async function loadReview(attempt) {
  if(attempt.review&&attempt.history&&attempt.reviewVersion===attempt.version)return;
  const [questions,history]=await Promise.all([cloud.readRpc("idrg_review",{p_id:attempt.id}),cloud.readRpc("idrg_attempt_history",{p_id:attempt.id})]);
  attempt.review=Object.fromEntries(questions.map(q=>[q.item_id,q]));attempt.history=history;attempt.reviewVersion=attempt.version;
}
function attemptStats(attempt,entries) {
  const stats=summarize(reviewFor(entries,attempt?.answers??{}));
  if(attempt?.finished){stats.right=attempt.correctCount;stats.total=attempt.totalCount;stats.wrong=stats.answered-stats.right;}
  return stats;
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
    const stats = attemptStats(attempt,entries);
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
      : attempt ? (attempt.editCount?"Draf revisi · ":"Draf · ") + stats.answered + "/" + stats.total + " terisi" : "Belum dimulai · " + stats.total + " butir";
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
    const stats = attemptStats(attempt,availableCases(packet.id));
    if (attempt?.finished) { submitted++; right += stats.right; total += stats.total; }
    const row = make("tr");
    row.append(make("td",packet.name));
    const status = make("td");
    status.append(make("span",attempt?.finished ? (attempt.editCount?"Revisi selesai":"Selesai") : attempt ? (attempt.editCount?"Draf revisi":"Draf") : "Belum dikerjakan",
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
  for(const attempt of profile.olderMaterials??[]){
    const packet=moduleInfo(attempt.packetId),row=make("tr");
    row.className="archived-attempt";
    row.append(make("td",packet.name+" · versi "+attempt.revision),make("td",attempt.finished?"Hasil sebelumnya":"Draf sebelumnya"),
      make("td",attempt.finished?attempt.correctCount+" / "+attempt.totalCount:"—"),
      make("td",attempt.finished?grade(attempt.correctCount,attempt.totalCount):"—"));
    const cell=make("td"),button=make("button",attempt.finished?"Lihat hasil lama":"Lanjutkan versi lama","secondary");
    button.type="button";button.addEventListener("click",()=>openModule(attempt.packetId,attempt));cell.append(button);row.append(cell);$("score-table").append(row);
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
  const review = reviewFor(cases(), session.answers, session.review);
  const {right, total, wrong, missing} = summarize(review);
  $("result-title").textContent = "Nilai " + moduleInfo(activeModule).name;
  $("result-student").textContent = profile.name + " · " + moduleInfo(activeModule).title + " · Versi " + session.revision;
  $("score").replaceChildren(document.createTextNode(grade(right, total)), make("small", " / 100"));
  $("result-key").replaceChildren();
  [[right + " / " + total, "Benar"], [wrong, "Salah"], [missing, "Kosong"]].forEach(([value, name]) => {
    const box = make("div", undefined, "card");
    box.append(make("strong", value), make("span", name, "small muted"));
    $("result-key").append(box);
  });
  $("revise-answers").disabled=session.editCount>=1;
  $("revise-answers").textContent=session.editCount>=1?"Kesempatan revisi sudah digunakan":"Revisi jawaban (1×)";
  $("revision-summary").textContent=(session.history??[]).map(h=>(h.round===0?"Nilai awal":"Nilai revisi")+": "+grade(h.correct_count,h.total_count)+" / 100").join(" · ");
  $("filter-review").setAttribute("aria-pressed", wrongOnly);
  $("filter-review").textContent = wrongOnly ? "Tampilkan semua pembahasan" : "Tampilkan yang perlu ditinjau";
  $("review").replaceChildren();
  review.forEach(({case: c, items}) => {
    const correct = items.filter(i => i.correct).length;
    if (wrongOnly && correct === items.length) return;
    const details = make("details", undefined, "review-case");
    const summary = make("summary", (c.displayId??c.id) + " · " + c.title);
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
      const correction=correctionFor(session.revision,keyFor(c,i));
      if(correction)panel.append(make("p",correction,"auth-message"));
      details.append(panel);
    });
    if (c.reference) details.append(make("p", c.reference, "muted small"));
    $("review").append(details);
  });
  if (!$("review").childElementCount) $("review").append(make("p", "Semua jawaban benar."));
  if (focus) $("result-title").focus({preventScroll:true});
}
$("pause").addEventListener("click", async () => {try {await flushSave();renderRecap();}catch(error){notify(cloud.friendly(error),true);}});
$("switch-participant").addEventListener("click", logout);
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
$("finish").addEventListener("click", async () => {
  $("finish").disabled=true;
  const attempt=session,owner=identity?.id;
  try {
    await flushSave();
    const row=await cloud.rpc("idrg_submit_attempt",{p_id:attempt.id,p_answers:attempt.answers,p_version:attempt.version});
    if(identity?.id!==owner||session?.id!==attempt.id)return;
    Object.assign(session,cloud.attemptFromRow(row),{dirty:false});
    await loadReview(session);
    if(identity?.id!==owner||session?.id!==attempt.id)return;
    $("confirm-submit").close();
    wrongOnly=false;renderResult();notify("");
    try {localStorage.removeItem(draftKey(session));}catch{}
  } catch(error) {notify(cloud.friendly(error),!session?.finished);}
  finally {$("finish").disabled=false;}
});
$("revise-answers").addEventListener("click",()=>{if(session?.finished&&session.editCount<1)$("confirm-revision").showModal();});
$("cancel-revision").addEventListener("click",()=>$("confirm-revision").close());
$("start-revision").addEventListener("click",async()=>{
  const attempt=session,owner=identity?.id;$("start-revision").disabled=true;
  try{
    const row=await cloud.rpc("idrg_reopen_attempt",{p_id:attempt.id,p_version:attempt.version});
    if(identity?.id!==owner||session?.id!==attempt.id)return;
    Object.assign(attempt,cloud.attemptFromRow(row),{dirty:false});
    $("confirm-revision").close();screen("practice");renderCase(true);
    notify("Revisi dibuka. Periksa jawaban lalu kirim kembali; kesempatan ini hanya tersedia satu kali.");
  }catch(error){notify(cloud.friendly(error));}finally{$("start-revision").disabled=false;}
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
    if (button.dataset.screen === "admin") return openAdmin();
    if (button.dataset.screen === "account") return openAccount();
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
  if (pdf) {
    if (!$("case-pdf").querySelector("canvas")) renderCasePdf(cases()[position()].pdf);
  } else {
    releasePdfContainer();
  }
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
    $("case-pdf").replaceChildren(make("p","PDF belum dapat dimuat. Gunakan Buka pada bilah berkas.","pdf-status"));
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
    const stats = attemptStats(attempt,availableCases(packet.id));
    rows.push([profile.name,packet.name,attempt?.finished ? (attempt.editCount?"Revisi selesai":"Selesai") : attempt ? (attempt.editCount?"Draf revisi":"Draf") : "Belum dikerjakan",
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

function authMessage(message,error=false,retry=false){
  $("auth-message").hidden=!message;
  $("auth-message").textContent=message;
  $("auth-message").classList.toggle("error",error);
  $("auth-retry").hidden=!retry;
}
function authMode(mode){
  for(const [key,id] of Object.entries({login:"setup",register:"register-form",reset:"reset-form",update:"update-password-form"}))$(id).hidden=key!==mode;
  $("auth-login").setAttribute("aria-pressed",mode==="login");
  $("auth-register").setAttribute("aria-pressed",mode==="register");
  authMessage("");
}
async function withForm(form,work){
  const button=form.querySelector('button[type="submit"]');button.disabled=true;
  try{await work();}catch(error){authMessage(cloud.friendly(error),true);}finally{button.disabled=false;}
}
function identityFields(prefix){
  const values={full_name:$(prefix+"-name").value.trim(),username:$(prefix+"-username").value.trim().toLowerCase(),phone:$(prefix+"-phone").value.trim(),institution:$(prefix+"-institution").value.trim()};
  if(!/^\+?[0-9 ()-]{8,25}$/.test(values.phone)||values.phone.replace(/[^0-9]/g,"").length<8||values.phone.replace(/[^0-9]/g,"").length>15)throw new Error("Nomor telepon harus berisi 8–15 digit. Tanda +, spasi, tanda hubung, dan kurung diperbolehkan.");
  return values;
}
function clearIdentity(){
  authEpoch++;moduleRequest++;clearTimeout(saveTimer);identity=null;profile=null;session=null;activeModule=null;isAdmin=false;adminData=null;
  for(const id of ["detail-name","detail-contact","recap-student","recap-name","result-student"])$(id).textContent="";
  $("nav-admin").hidden=true;$("nav-account").hidden=true;
  for(const id of ["admin-rows","detail-packets","detail-review","review","score-table","recap-modules","recap-casemix"])$(id).replaceChildren();
  for(const form of ["setup","register-form","reset-form","update-password-form","profile-form"])$(form).reset();
  $("save-state").textContent="Belum masuk";
  authMode("login");startPage();
}
async function restoreAccount(knownUser=null){
  if(restoring)return restoring;
  const epoch=authEpoch;
  restoring=(async()=>{
    try{
      const account=await cloud.loadAccount(knownUser);
      if(epoch!==authEpoch)return;
      if(!account){clearIdentity();return;}
      identity=account.user;isAdmin=account.admin;
      profile={name:account.person?.full_name??account.user.email,person:account.person,complete:!!account.person,materials:{},olderMaterials:[]};
      for(const row of account.attempts){
        const attempt={...cloud.attemptFromRow(row),packetId:row.packet_id};
        if(row.revision===bankRevision)profile.materials[row.packet_id]=attempt;
        else profile.olderMaterials.push(attempt);
      }
      $("nav-admin").hidden=!isAdmin;$("nav-account").hidden=false;
      $("save-state").textContent="Terhubung ke akun Anda";
      if(!profile.complete)openAccount();else if(isAdmin)await openAdmin();else renderRecap();
    }catch(error){startPage();authMessage(cloud.friendly(error),true,true);}
  })();
  try{await restoring;}finally{restoring=null;}
}
$("auth-retry").addEventListener("click",async()=>{
  $("auth-retry").disabled=true;
  try{await restoreAccount();}finally{$("auth-retry").disabled=false;}
});
async function logout(){
  try{await flushSave();}catch{} // Unsynced answers remain in the account-specific recovery cache.
  const {error}=await cloud.client.auth.signOut({scope:"local"});
  if(error){notify(cloud.friendly(error));return;}
  recovering=false;notify("");
}
$("auth-login").addEventListener("click",()=>authMode("login"));
$("auth-register").addEventListener("click",()=>authMode("register"));
$("auth-forgot").addEventListener("click",()=>{authMode("reset");$("reset-email").value=$("login-email").value;});
$("setup").addEventListener("submit",event=>{
  event.preventDefault();withForm(event.currentTarget,async()=>{
    authMessage("");
    const {data,error}=await cloud.client.auth.signInWithPassword({email:$("login-email").value.trim(),password:$("login-password").value});
    $("login-password").value="";
    if(error)throw error;
    await restoreAccount(data.user);
  });
});
$("register-form").addEventListener("submit",event=>{
  event.preventDefault();withForm(event.currentTarget,async()=>{
    const metadata=identityFields("register");
    const email=$("register-email").value.trim(),password=$("register-password").value;
    try{
      await cloud.requireDirectSignup();
      const {data,error}=await cloud.client.auth.signUp({email,password,options:{data:metadata}});
      if(error)throw error;
      let sessionUser=data.user;
      if(!data.session){
        const signed=await cloud.client.auth.signInWithPassword({email,password});
        if(signed.error)throw signed.error;
        sessionUser=signed.data.user;
      }
      await restoreAccount(sessionUser);
    }finally{$("register-password").value="";}
  });
});
$("reset-form").addEventListener("submit",event=>{
  event.preventDefault();withForm(event.currentTarget,async()=>{
    const {error}=await cloud.client.auth.resetPasswordForEmail($("reset-email").value.trim(),{redirectTo:location.origin+location.pathname});
    if(error)throw error;authMessage("Jika email terdaftar, tautan pemulihan akan dikirim. Periksa kotak masuk dan folder spam.");
  });
});
$("update-password-form").addEventListener("submit",event=>{
  event.preventDefault();withForm(event.currentTarget,async()=>{
    const {error}=await cloud.client.auth.updateUser({password:$("new-password").value});
    $("new-password").value="";if(error)throw error;
    recovering=false;await restoreAccount();notify("Password berhasil diperbarui.");
  });
});
$("dismiss-message").addEventListener("click",()=>notify(""));
$("retry-save").addEventListener("click",()=>flushSave().catch(error=>notify(cloud.friendly(error),true)));
window.addEventListener("online",()=>{if(session?.dirty)flushSave().catch(error=>notify(cloud.friendly(error),true));});
window.addEventListener("beforeunload",event=>{if(session?.dirty){event.preventDefault();event.returnValue="";}});
function openAccount(){
  if(!profile)return startPage();
  const person=profile.person??{};
  for(const [id,key]of [["name","full_name"],["username","username"],["phone","phone"],["institution","institution"]])$("profile-"+id).value=person[key]??"";
  $("profile-email").value=identity.email??"";
  $("profile-message").textContent=profile.complete?"":"Lengkapi identitas sebelum mulai mengerjakan latihan.";
  screen("account");
}
$("profile-form").addEventListener("submit",async event=>{
  event.preventDefault();const button=event.currentTarget.querySelector('button[type="submit"]');button.disabled=true;
  try{
    const values=identityFields("profile");
    const person=await cloud.rpc("idrg_complete_profile",{p_full_name:values.full_name,p_username:values.username,p_phone:values.phone,p_institution:values.institution});
    profile.person=person;profile.name=person.full_name;profile.complete=true;
    $("profile-message").textContent="Identitas berhasil disimpan.";renderRecap();notify("Identitas berhasil disimpan.");
  }catch(error){$("profile-message").textContent=cloud.friendly(error);}finally{button.disabled=false;}
});
let adminPage=0,adminData=null;
async function openAdmin(reset=true){
  if(!isAdmin)return;
  if(reset)adminPage=0;
  const owner=identity?.id;
  screen("admin");$("admin-status").textContent="Memuat data peserta…";
  try{
    const selected=$("admin-institution").value;
    const response=await cloud.readRpc("idrg_admin_dashboard",{p_search:$("admin-search").value.trim(),p_institution:selected,p_page:adminPage,p_page_size:25});
    if(!isAdmin||identity?.id!==owner)return;
    adminData=response;
    $("admin-participants").textContent=adminData.participants;
    $("admin-submitted").textContent=adminData.submitted;
    $("admin-average").textContent=adminData.average===null?"—":scoreNumber.format(Number(adminData.average));
    $("admin-institution").replaceChildren(make("option","Semua instansi"));$("admin-institution").firstChild.value="";
    for(const name of adminData.institutions){const option=make("option",name);option.value=name;$("admin-institution").append(option);}
    $("admin-institution").value=selected;
    $("admin-material-averages").replaceChildren();
    for(const packet of modules){
      const summary=adminData.materials?.find(item=>item.packet_id===packet.id);
      const card=make("article",undefined,"card"),body=make("div");
      body.append(make("h3",packet.name),make("p",summary?.average==null?"Belum ada nilai":scoreNumber.format(Number(summary.average))+" / 100","material-average"),make("p",(summary?.submitted??0)+" peserta sudah mengirim","small muted"));
      card.append(body);$("admin-material-averages").append(card);
    }
    $("admin-rows").replaceChildren();
    for(const person of adminData.rows){
      const row=make("tr"),name=make("td");name.append(make("b",person.full_name),make("small",person.email),make("small","@"+person.username));row.append(name,make("td",person.institution));
      let right=0,total=0;
      for(const packet of modules){
        const attempt=person.attempts.find(a=>a.packet_id===packet.id);
        let value="Belum mulai";
        if(attempt?.submitted_at){value=grade(attempt.correct_count,attempt.total_count)+(attempt.edit_count?" · revisi":"");right+=attempt.correct_count;total+=attempt.total_count;}
        else if(attempt)value=(attempt.edit_count?"Draf revisi · ":"Draf · ")+Object.keys(attempt.answers).length+"/"+attempt.total_count;
        row.append(make("td",value));
      }
      row.append(make("td",total?grade(right,total):"—"));const cell=make("td"),button=make("button","Detail","secondary");
      button.type="button";button.addEventListener("click",()=>openAdminDetail(person));cell.append(button);row.append(cell);$("admin-rows").append(row);
    }
    if(!adminData.rows.length){const row=make("tr"),cell=make("td","Belum ada peserta yang sesuai filter.");cell.colSpan=8;row.append(cell);$("admin-rows").append(row);}
    $("admin-status").textContent="Data diperbarui · "+new Date().toLocaleString("id-ID");
    $("admin-page").textContent="Halaman "+(adminPage+1)+" dari "+Math.max(1,Math.ceil(adminData.participants/25));
    $("admin-prev").disabled=adminPage===0;$("admin-next").disabled=(adminPage+1)*25>=adminData.participants;
  }catch(error){$("admin-status").textContent=cloud.friendly(error);}
}
function openAdminDetail(person){
  if(!isAdmin)return;screen("admin-detail");$("detail-name").textContent=person.full_name;
  $("detail-contact").textContent=[person.email,"@"+person.username,person.phone,person.institution].join(" · ");
  $("detail-packets").replaceChildren();$("detail-review").replaceChildren();
  for(const packet of modules){
    const attempt=person.attempts.find(a=>a.packet_id===packet.id);
    const card=make("article",undefined,"card"),body=make("div");
    body.append(make("h3",packet.name),make("p",attempt?.submitted_at?"Nilai "+grade(attempt.correct_count,attempt.total_count)+" / 100 · "+new Date(attempt.submitted_at).toLocaleString("id-ID"):attempt?Object.keys(attempt.answers).length+" dari "+attempt.total_count+" soal terisi":"Belum mulai","small muted"));
    card.append(body);
    if(attempt){const button=make("button","Lihat jawaban","secondary");button.type="button";button.addEventListener("click",()=>adminReview(attempt));card.append(button);}
    $("detail-packets").append(card);
  }
}
async function adminReview(attempt){
  if(!isAdmin)return;const owner=identity?.id;
  $("detail-review").replaceChildren(make("p","Memuat jawaban…"));
  try{
    const draftBank=attempt.submitted_at?null:await bankForRevision(attempt.revision);
    const [questions,history]=await Promise.all([
      attempt.submitted_at?cloud.rpc("idrg_review",{p_id:attempt.id}):Promise.resolve(availableCases(attempt.packet_id,draftBank).flatMap(c=>c.items.map((q,i)=>({...q,item_id:keyFor(c,i)})))),
      cloud.rpc("idrg_attempt_history",{p_id:attempt.id})]);
    if(!isAdmin||identity?.id!==owner)return;
    $("detail-review").replaceChildren();
    if(history.length){const summary=make("article",undefined,"card");summary.append(make("h3","Riwayat nilai"),make("p",history.map(h=>(h.round===0?"Nilai awal":"Nilai revisi")+": "+grade(h.correct_count,h.total_count)+" / 100").join(" · ")));$("detail-review").append(summary);}
    for(const [i,q]of questions.entries()){
      const chosen=attempt.answers[q.item_id],answered=hasAnswer(chosen),card=make("article",undefined,"admin-review-item");
      card.append(make("h3",(i+1)+". "+q.prompt),make("p","Jawaban peserta: "+(answered?letter(Number(chosen))+". "+q.options[Number(chosen)]:"Belum dijawab")));
      if(attempt.submitted_at){card.append(make("p",String(q.correct)===chosen?"Benar":"Salah atau kosong",String(q.correct)===chosen?"correct":"incorrect"),make("p","Kunci: "+letter(q.correct)+". "+q.options[q.correct]),make("p",q.feedback));}
      const correction=attempt.submitted_at&&correctionFor(attempt.revision,q.item_id);
      if(correction)card.append(make("p",correction,"auth-message"));
      $("detail-review").append(card);
    }
  }catch(error){$("detail-review").replaceChildren(make("p",cloud.friendly(error)));}
}
$("admin-refresh").addEventListener("click",()=>openAdmin(false));
$("admin-filter").addEventListener("submit",event=>{event.preventDefault();openAdmin();});
$("admin-prev").addEventListener("click",()=>{adminPage--;openAdmin(false);});
$("admin-next").addEventListener("click",()=>{adminPage++;openAdmin(false);});
$("admin-back").addEventListener("click",()=>openAdmin(false));
async function initializeAccount(){
  startPage();authMode("login");
  cloud.client.auth.onAuthStateChange((event)=>{
    if(event==="PASSWORD_RECOVERY"){recovering=true;startPage();authMode("update");}
    else if(event==="SIGNED_OUT"){clearIdentity();}
    else if(event==="SIGNED_IN"&&!identity&&!recovering)setTimeout(()=>restoreAccount(),0);
  });
  const {data:{session:authSession}}=await cloud.client.auth.getSession();
  if(authSession&&!recovering)await restoreAccount();
}
initializeAccount().catch(error=>authMessage(cloud.friendly(error),true));
