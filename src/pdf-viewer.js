import * as pdfjs from "./vendor/pdf.mjs";

pdfjs.GlobalWorkerOptions.workerSrc = "./vendor/pdf.worker.mjs";
const MAX_CACHED_PDFS = 6;
const MAX_CANVAS_SIDE = 2200;
const pdfByteCache = new Map();
let request = 0;
let task = null;
let loadedUrl = null;
let loadedDoc = null;
let activeRenderTask = null;
let resizeTimer = null;
let current = null;
let lastContainerWidth = 0;

function releaseCanvases(container) {
  container.querySelectorAll("canvas").forEach(canvas => {
    canvas.width = 0;
    canvas.height = 0;
  });
  container.replaceChildren();
}

function cancelActiveRender() {
  if (!activeRenderTask) return;
  try {
    activeRenderTask.cancel();
  } catch {}
  activeRenderTask = null;
}

async function getPdfBytes(url) {
  if (pdfByteCache.has(url)) {
    const cached = pdfByteCache.get(url);
    pdfByteCache.delete(url);
    pdfByteCache.set(url, cached);
    return cached;
  }
  const response = await fetch(url);
  if (!response.ok) throw new Error("PDF HTTP " + response.status);
  const bytes = await response.arrayBuffer();
  if (pdfByteCache.size >= MAX_CACHED_PDFS) {
    pdfByteCache.delete(pdfByteCache.keys().next().value);
  }
  pdfByteCache.set(url, bytes);
  return bytes;
}

export function clearPdf(container) {
  request++;
  cancelActiveRender();
  current = null;
  lastContainerWidth = 0;
  if (container) {
    releaseCanvases(container);
    container.setAttribute("aria-busy", "false");
  }
  loadedDoc = null;
  loadedUrl = null;
  const previous = task;
  task = null;
  if (previous) previous.destroy().catch(() => {});
}

export async function renderPdf(url, container, zoom = 1) {
  const id = ++request;
  cancelActiveRender();
  current = {url, container, zoom};
  const style = getComputedStyle(container);
  const padding = (parseFloat(style.paddingLeft) || 0) + (parseFloat(style.paddingRight) || 0);
  const clientWidth = container.clientWidth;
  lastContainerWidth = clientWidth;
  const containerWidth = Math.max(240, clientWidth - padding);
  container.setAttribute("aria-busy", "true");
  try {
    if (loadedUrl !== url || !loadedDoc) {
      loadedDoc = null;
      loadedUrl = null;
      const previous = task;
      task = null;
      if (previous) await previous.destroy().catch(() => {});
      if (id !== request) return;
      releaseCanvases(container);
      const status = document.createElement("p");
      status.className = "pdf-status";
      status.textContent = "Memuat berkas PDF…";
      container.append(status);
      const bytes = await getPdfBytes(url);
      if (id !== request) return;
      task = pdfjs.getDocument({
        data: bytes.slice(0),
        isEvalSupported: false,
        standardFontDataUrl: "./vendor/standard_fonts/"
      });
      const doc = await task.promise;
      if (id !== request) return;
      loadedDoc = doc;
      loadedUrl = url;
      status.remove();
    }
    releaseCanvases(container);
    for (let number = 1; number <= loadedDoc.numPages; number++) {
      const page = await loadedDoc.getPage(number);
      if (id !== request) {
        page.cleanup();
        return;
      }
      const base = page.getViewport({scale:1});
      const width = containerWidth * zoom;
      const viewport = page.getViewport({scale:width / base.width});
      const baseRatio = Math.min(window.devicePixelRatio || 1, 2);
      const ratio = Math.min(baseRatio, MAX_CANVAS_SIDE / Math.max(viewport.width, viewport.height, 1));
      const canvas = globalThis.document.createElement("canvas");
      canvas.width = Math.ceil(viewport.width * ratio);
      canvas.height = Math.ceil(viewport.height * ratio);
      canvas.style.width = width + "px";
      canvas.style.height = "auto";
      canvas.setAttribute("role", "img");
      canvas.setAttribute("aria-label", "Halaman " + number + ". Versi teks tersedia di tab Teks berkas.");
      const renderTask = page.render({
        canvasContext: canvas.getContext("2d"),
        viewport,
        transform: [ratio, 0, 0, ratio, 0, 0]
      });
      activeRenderTask = renderTask;
      try {
        await renderTask.promise;
      } finally {
        if (activeRenderTask === renderTask) activeRenderTask = null;
        page.cleanup();
      }
      if (id !== request) {
        canvas.width = 0;
        canvas.height = 0;
        return;
      }
      container.append(canvas);
    }
  } catch (error) {
    if (id !== request || error?.name === "RenderingCancelledException") return;
    releaseCanvases(container);
    const status = document.createElement("p");
    status.className = "pdf-status";
    status.textContent = "PDF belum dapat dimuat. Gunakan Buka pada bilah berkas.";
    container.append(status);
    throw error;
  } finally {
    if (id === request) container.setAttribute("aria-busy", "false");
  }
}

window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (current && !current.container.hidden && current.container.offsetParent &&
        Math.abs(current.container.clientWidth - lastContainerWidth) > 8) {
      renderPdf(current.url, current.container, current.zoom).catch(() => {});
    }
  }, 180);
});
