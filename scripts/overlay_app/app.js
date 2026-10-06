const dropzone = document.getElementById("dropzone");
const fileInput = document.getElementById("file-input");
const uploadSection = document.getElementById("upload-section");
const reloadHint = document.getElementById("reload-hint");
const loadedFilename = document.getElementById("loaded-filename");
const errorBox = document.getElementById("error-box");

const sessionPanel = document.getElementById("session-panel");
const performancePanel = document.getElementById("performance-panel");
const channelsPanel = document.getElementById("channels-panel");
const channelList = document.getElementById("channel-list");
const metaDuration = document.getElementById("meta-duration");
const metaRows = document.getElementById("meta-rows");

const previewWrap = document.getElementById("preview-wrap");
const previewImg = document.getElementById("preview-img");
const scrub = document.getElementById("scrub");
const scrubTime = document.getElementById("scrub-time");

const fpsInput = document.getElementById("fps-input");
const formatSelect = document.getElementById("format-select");
const formatHint = document.getElementById("format-hint");
const renderBtn = document.getElementById("render-btn");

const progressWrap = document.getElementById("progress-wrap");
const progressBar = document.getElementById("progress-bar");
const progressText = document.getElementById("progress-text");
const downloadRow = document.getElementById("download-row");
const downloadLink = document.getElementById("download-link");

let sessionDuration = 0;
let pollTimer = null;

function fmtTime(t) {
  const mm = Math.floor(t / 60);
  const ss = (t % 60).toFixed(1).padStart(4, "0");
  return `${mm}:${ss}`;
}

function showError(msg) {
  errorBox.textContent = msg;
  errorBox.classList.add("active");
}

function clearError() {
  errorBox.textContent = "";
  errorBox.classList.remove("active");
}

dropzone.addEventListener("click", () => fileInput.click());
reloadHint.addEventListener("click", () => fileInput.click());

dropzone.addEventListener("dragover", (e) => {
  e.preventDefault();
  dropzone.classList.add("drag");
});
dropzone.addEventListener("dragleave", () => dropzone.classList.remove("drag"));
dropzone.addEventListener("drop", (e) => {
  e.preventDefault();
  dropzone.classList.remove("drag");
  if (e.dataTransfer.files.length) uploadFile(e.dataTransfer.files[0]);
});
fileInput.addEventListener("change", () => {
  if (fileInput.files.length) uploadFile(fileInput.files[0]);
});

async function uploadFile(file) {
  clearError();
  downloadRow.classList.remove("active");
  progressWrap.classList.remove("active");
  renderBtn.disabled = true;

  try {
    const buf = await file.arrayBuffer();
    const resp = await fetch("/api/upload", {
      method: "POST",
      headers: {
        "Content-Type": "application/octet-stream",
        "X-Filename": encodeURIComponent(file.name),
      },
      body: buf,
    });
    const data = await resp.json();
    if (!resp.ok) {
      showError(data.error || "Upload failed.");
      return;
    }

    sessionDuration = data.duration;
    metaDuration.textContent = fmtTime(data.duration);
    metaRows.textContent = data.rows.toLocaleString();

    scrub.max = data.duration;
    scrub.value = 0;
    scrubTime.textContent = fmtTime(0);
    previewWrap.classList.add("active");
    updatePreview(0);

    channelList.innerHTML = "";
    for (const [key, ch] of Object.entries(data.channels)) {
      const row = document.createElement("div");
      row.className = "channel-row " + (ch.dead ? "dead" : "live");
      row.innerHTML = `<span class="name">${ch.label}</span><span class="status">${ch.dead ? "Dead" : "Live"}</span>`;
      channelList.appendChild(row);
    }

    const peakG = data.peak_g || {};
    const dragy = data.dragy || {};
    const fmtG = (v) => (typeof v === "number" ? v.toFixed(2) + "g" : "—");
    document.getElementById("perf-lat-g").textContent = fmtG(peakG.peak_lat_g);
    document.getElementById("perf-accel-g").textContent = fmtG(peakG.peak_accel_g);
    document.getElementById("perf-brake-g").textContent = fmtG(peakG.peak_brake_g);
    document.getElementById("perf-0-100").textContent = dragy.zero_to_100_s != null ? dragy.zero_to_100_s.toFixed(2) + "s" : "—";
    document.getElementById("perf-0-60").textContent = dragy.zero_to_60mph_s != null ? dragy.zero_to_60mph_s.toFixed(2) + "s" : "—";
    document.getElementById("perf-quarter").textContent = dragy.quarter_mile_s != null
      ? `${dragy.quarter_mile_s.toFixed(2)}s @ ${dragy.quarter_mile_trap_kmh.toFixed(0)}km/h`
      : "—";

    sessionPanel.style.display = "";
    performancePanel.style.display = (data.peak_g && data.dragy) ? "" : "none";
    channelsPanel.style.display = "";
    uploadSection.classList.add("collapsed");
    loadedFilename.textContent = file.name;
    renderBtn.disabled = false;
  } catch (err) {
    showError(String(err));
  }
}

let scrubTimer = null;
scrub.addEventListener("input", () => {
  const t = parseFloat(scrub.value);
  scrubTime.textContent = fmtTime(t);
  clearTimeout(scrubTimer);
  scrubTimer = setTimeout(() => updatePreview(t), 60);
});

function updatePreview(t) {
  previewImg.src = `/api/frame?t=${t}&_=${Date.now()}`;
}

function updateFormatHint() {
  if (formatSelect.value === "prores") {
    formatHint.textContent = "Recommended for editors. Large files (easily 500MB+ for a full session), but every major NLE reads its frame rate correctly.";
  } else {
    formatHint.textContent = "Small, but many editors (Final Cut, some Premiere/Resolve versions) read WebM/VP9 frame rate unreliably or not at all, which can play it back too fast. Fine for quick previews in VLC/a browser.";
  }
}
formatSelect.addEventListener("change", updateFormatHint);
updateFormatHint();

renderBtn.addEventListener("click", async () => {
  clearError();
  renderBtn.disabled = true;
  downloadRow.classList.remove("active");
  progressWrap.classList.add("active");
  progressBar.style.width = "0%";
  progressText.textContent = "Starting...";

  try {
    const resp = await fetch("/api/render", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        fps: parseFloat(fpsInput.value) || 20,
        format: formatSelect.value,
      }),
    });
    const data = await resp.json();
    if (!resp.ok) {
      showError(data.error || "Render failed to start.");
      renderBtn.disabled = false;
      progressWrap.classList.remove("active");
      return;
    }
    pollStatus(data.job_id);
  } catch (err) {
    showError(String(err));
    renderBtn.disabled = false;
    progressWrap.classList.remove("active");
  }
});

function pollStatus(jobId) {
  clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    try {
      const resp = await fetch(`/api/render/status?id=${jobId}`);
      const data = await resp.json();
      if (!resp.ok) {
        clearInterval(pollTimer);
        showError(data.error || "Render failed.");
        renderBtn.disabled = false;
        return;
      }

      if (data.status === "rendering") {
        const pct = data.total ? (data.rendered / data.total) * 100 : 0;
        progressBar.style.width = pct.toFixed(0) + "%";
        progressText.textContent = `Rendering frame ${data.rendered} / ${data.total}`;
      } else if (data.status === "encoding") {
        progressBar.style.width = "100%";
        progressText.textContent = "Encoding video...";
      } else if (data.status === "done") {
        clearInterval(pollTimer);
        progressBar.style.width = "100%";
        progressText.textContent = "Done.";
        downloadLink.href = `/api/render/download?id=${jobId}`;
        downloadRow.classList.add("active");
        renderBtn.disabled = false;
      } else if (data.status === "error") {
        clearInterval(pollTimer);
        showError(data.error || "Render failed.");
        renderBtn.disabled = false;
      }
    } catch (err) {
      clearInterval(pollTimer);
      showError(String(err));
      renderBtn.disabled = false;
    }
  }, 700);
}
