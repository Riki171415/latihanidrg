import * as pdfjs from "./vendor/pdf.mjs";

pdfjs.GlobalWorkerOptions.workerSrc = "./vendor/pdf.worker.mjs";
let request = 0;
let task = null;
let resizeTimer = null;
let current = null;

export async function renderPdf(url, container) {
  const id = ++request;
  current = {url,container};
  const previous = task;
  task = null;
  if (previous) await previous.destroy().catch(() => {});
  if (id !== request) return;
  container.replaceChildren();
  const status = document.createElement("p");
  status.className = "pdf-status";
  status.textContent = "Memuat berkas PDF…";
  container.append(status);
  container.setAttribute("aria-busy","true");
  try {
    task = pdfjs.getDocument({url, isEvalSupported:false,standardFontDataUrl:"./vendor/standard_fonts/"});
    const document = await task.promise;
    if (id !== request) return;
    status.remove();
    for (let number = 1; number <= document.numPages; number++) {
      const page = await document.getPage(number);
      if (id !== request) return;
      const base = page.getViewport({scale:1});
      const width = Math.max(240,container.clientWidth - 22);
      const viewport = page.getViewport({scale:width / base.width});
      const ratio = Math.min(window.devicePixelRatio || 1,2);
      const canvas = globalThis.document.createElement("canvas");
      canvas.width = Math.ceil(viewport.width * ratio);
      canvas.height = Math.ceil(viewport.height * ratio);
      canvas.style.width = "100%";
      canvas.style.height = "auto";
      canvas.setAttribute("role","img");
      canvas.setAttribute("aria-label","Halaman " + number + ". Versi teks tersedia di tab Teks berkas.");
      container.append(canvas);
      await page.render({canvasContext:canvas.getContext("2d"), viewport,transform:[ratio,0,0,ratio,0,0]}).promise;
    }
  } catch(error) {
    if (id !== request) return;
    container.replaceChildren(status);
    status.textContent = "PDF belum dapat dimuat. Gunakan Buka atau Unduh pada bilah berkas.";
    throw error;
  } finally {
    if (id === request) container.setAttribute("aria-busy","false");
  }
}
window.addEventListener("resize",() => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (current && !current.container.hidden && current.container.offsetParent) {
      renderPdf(current.url,current.container).catch(() => {});
    }
  },180);
});
