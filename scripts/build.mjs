import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

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
await fs.mkdir(dist,{recursive:true});
await fs.cp(path.join(root,"public"),dist,{recursive:true});
const template = await fs.readFile(path.join(root,"index.html"),"utf8");
const payload = JSON.stringify(data).replaceAll("<","\u003c");
await fs.writeFile(path.join(dist,"index.html"),template.replace("__CASE_DATA__",payload));
for (const file of ["app.js","styles.css","pdf-viewer.js"]) await fs.copyFile(path.join(root,"src",file),path.join(dist,file));
await fs.mkdir(path.join(dist,"vendor"),{recursive:true});
for (const file of ["pdf.mjs","pdf.worker.mjs"]) {
  await fs.copyFile(path.join(root,"node_modules/pdfjs-dist/build",file),path.join(dist,"vendor",file));
}
await fs.copyFile(path.join(root,"node_modules/pdfjs-dist/LICENSE"),path.join(dist,"vendor","pdfjs-LICENSE.txt"));
console.log("Build selesai — 28 PDF, 4 paket praktik, 112 soal A–E.");
