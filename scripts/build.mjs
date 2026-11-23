import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {build} from "esbuild";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dist = path.join(root, "dist");
const data = JSON.parse(await fs.readFile(path.join(root,"src/cases.json"),"utf8"));
if (data.length !== 28 || data.reduce((n,c) => n + c.items.length,0) !== 112) {
  throw new Error("Bank soal harus berisi 28 kasus dan 112 butir.");
}
const ids = new Set();
for (const item of data) {
  if (ids.has(item.id)) throw new Error("Nomor kasus ganda " + item.id);
  ids.add(item.id);
  if(item.id!=="M2-01"&&(!item.simulation||item.records.length<10))throw new Error("Resume klinis belum lengkap "+item.id);
  if(item.contentRevision!==data[0].contentRevision)throw new Error("Versi naskah soal tidak konsisten.");
  if (!item.pdf.startsWith("cases/") || item.pdf.includes("..")) throw new Error("Path PDF tidak valid.");
  const pdf = await fs.readFile(path.join(root,"public",item.pdf));
  if (pdf.subarray(0,5).toString() !== "%PDF-") throw new Error("PDF tidak valid " + item.id);
  for (const question of item.items) {
    if (question.options.length !== 5 || new Set(question.options).size !== 5 ||
        !Number.isInteger(question.correct) || question.correct < 0 || question.correct > 4) {
      throw new Error("Pilihan atau kunci tidak valid " + item.id);
    }
  }
}
// Historical banks are public question text only; never ship grading keys.
const oldBank=JSON.parse(await fs.readFile(path.join(root,"public/banks/2026-11-23.3.json"),"utf8"));
if(oldBank.length!==28||oldBank.some(c=>c.items.some(q=>"correct" in q||"feedback" in q)))throw new Error("Arsip publik tidak valid.");
await fs.mkdir(dist,{recursive:true});
await fs.cp(path.join(root,"public"),dist,{recursive:true});
const template = await fs.readFile(path.join(root,"index.html"),"utf8");
const publicBank=data.map(c=>({id:c.id,module:c.module,title:c.title,records:c.records,pdf:c.pdf,
  reference:c.reference,displayId:c.displayId,displayModule:c.displayModule,simulation:c.simulation,documentType:c.documentType,contentRevision:c.contentRevision,items:c.items.map(q=>({prompt:q.prompt,options:q.options}))}));
const payload = JSON.stringify(publicBank).replaceAll("<",String.fromCharCode(92)+"u003c");
const config=JSON.parse(await fs.readFile(path.join(root,'src/config.json'),'utf8'));
config.supabaseUrl=process.env.SUPABASE_URL||config.supabaseUrl;
config.supabasePublishableKey=process.env.SUPABASE_PUBLISHABLE_KEY||config.supabasePublishableKey;
const endpoint=new URL(config.supabaseUrl); if(endpoint.protocol!=="https:"||!endpoint.hostname.endsWith(".supabase.co")||!config.supabasePublishableKey.startsWith("sb_publishable_"))throw new Error("Invalid public Supabase configuration.");
await fs.writeFile(path.join(dist,"index.html"),template.replace("__CASE_DATA__",payload).replace("__APP_CONFIG__",JSON.stringify(config).replaceAll("<",String.fromCharCode(92)+"u003c")));
await build({entryPoints:[path.join(root,'src/cloud.js')],bundle:true,format:'iife',globalName:'IDRGCloud',outfile:path.join(dist,'cloud.js'),minify:true,target:'es2022',legalComments:'eof'});
for (const file of ["app.js","styles.css","pdf-viewer.js"]) await fs.copyFile(path.join(root,"src",file),path.join(dist,file));
await fs.mkdir(path.join(dist,"vendor"),{recursive:true});
for (const file of ["pdf.mjs","pdf.worker.mjs"]) {
  await fs.copyFile(path.join(root,"node_modules/pdfjs-dist/build",file),path.join(dist,"vendor",file));
}
await fs.copyFile(path.join(root,"node_modules/pdfjs-dist/LICENSE"),path.join(dist,"vendor","pdfjs-LICENSE.txt"));
await fs.cp(path.join(root,"node_modules/pdfjs-dist/standard_fonts"),path.join(dist,"vendor/standard_fonts"),{recursive:true});
console.log("Build selesai — 28 PDF, 4 paket praktik, 112 soal A–E.");
