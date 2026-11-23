import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import "./build.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)),"../dist");
const types = {".html":"text/html; charset=utf-8",".js":"text/javascript; charset=utf-8",".mjs":"text/javascript; charset=utf-8",
  ".css":"text/css; charset=utf-8",".pdf":"application/pdf",".svg":"image/svg+xml"};
const server = http.createServer(async (req,res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url,"http://localhost").pathname);
    const file = path.resolve(root,"." + (pathname === "/" ? "/index.html" : pathname));
    if (!file.startsWith(root + path.sep)) {res.writeHead(403);return res.end();}
    const bytes = await fs.readFile(file);
    res.writeHead(200,{"Content-Type":types[path.extname(file)]??"application/octet-stream"});
    res.end(bytes);
  } catch {res.writeHead(404);res.end("Tidak ditemukan");}
});
server.listen(4173,"127.0.0.1",() => console.log("http://127.0.0.1:4173"));
