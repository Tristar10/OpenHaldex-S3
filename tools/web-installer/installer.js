const sourceSelect = document.querySelector("#source");
const installButton = document.querySelector("#install-button");
const status = document.querySelector("#status");
const objectUrls = new Set();

const OFFSETS = {
  bootloader: 0x0000,
  partitions: 0x8000,
  otadata: 0xe000,
  firmware: 0x10000,
  littlefs: 0x790000,
};

function clearObjectUrls() {
  objectUrls.forEach((url) => URL.revokeObjectURL(url));
  objectUrls.clear();
}

function trackObjectUrl(value) {
  const url = URL.createObjectURL(value);
  objectUrls.add(url);
  return url;
}

function setManifest(manifest, message, ownsUrl = false) {
  clearObjectUrls();
  const url = ownsUrl ? trackObjectUrl(manifest) : manifest;
  installButton.manifest = url;
  installButton.setAttribute("manifest", url);
  status.textContent = message;
}

function customManifest(parts, name) {
  const manifest = {
    name,
    version: "custom",
    new_install_prompt_erase: true,
    new_install_improv_wait_time: 0,
    builds: [{ chipFamily: "ESP32-S3", parts }],
  };
  return new Blob([JSON.stringify(manifest)], { type: "application/json" });
}

function part(file, offset) {
  return { path: trackObjectUrl(file), offset };
}

sourceSelect.addEventListener("change", () => {
  document.querySelectorAll("[data-source]").forEach((panel) => {
    panel.hidden = panel.dataset.source !== sourceSelect.value;
  });
  if (sourceSelect.value === "local") {
    setManifest("./build/manifest.json", "Current local build is ready.");
  } else {
    status.textContent = "Choose a firmware source, then prepare it for installation.";
  }
});

document.querySelector("#use-local").addEventListener("click", () => {
  setManifest(`./build/manifest.json?time=${Date.now()}`, "Current local build is ready.");
});

document.querySelector("#use-manifest").addEventListener("click", () => {
  const input = document.querySelector("#manifest-url");
  try {
    const url = new URL(input.value);
    if (!['https:', 'http:'].includes(url.protocol)) {
      throw new Error("Unsupported address");
    }
    setManifest(url.href, `Manifest ready: ${url.href}`);
  } catch {
    status.textContent = "Enter a complete HTTP or HTTPS manifest address.";
    input.focus();
  }
});

document.querySelector("#split-form").addEventListener("submit", (event) => {
  event.preventDefault();
  clearObjectUrls();
  const data = new FormData(event.currentTarget);
  const bootloader = data.get("bootloader");
  const partitions = data.get("partitions");
  const firmware = data.get("firmware");
  const littlefs = data.get("littlefs");
  if (![bootloader, partitions, firmware].every((file) => file instanceof File && file.size)) {
    status.textContent = "Select bootloader, partitions, and firmware images first.";
    return;
  }

  const parts = [
    part(bootloader, OFFSETS.bootloader),
    part(partitions, OFFSETS.partitions),
    {
      path: trackObjectUrl(new Blob([new Uint8Array(0x2000).fill(0xff)])),
      offset: OFFSETS.otadata,
    },
    part(firmware, OFFSETS.firmware),
  ];
  if (littlefs instanceof File && littlefs.size) {
    parts.push(part(littlefs, OFFSETS.littlefs));
  }
  const manifest = customManifest(parts, "OpenHaldex S3 (selected files)");
  const manifestUrl = trackObjectUrl(manifest);
  installButton.manifest = manifestUrl;
  installButton.setAttribute("manifest", manifestUrl);
  status.textContent = littlefs.size
    ? "Selected firmware and WebUI images are ready."
    : "Selected firmware is ready; the existing LittleFS WebUI will be preserved unless flash is erased.";
});

document.querySelector("#merged-form").addEventListener("submit", (event) => {
  event.preventDefault();
  clearObjectUrls();
  const file = new FormData(event.currentTarget).get("merged");
  if (!(file instanceof File) || !file.size) {
    status.textContent = "Select a complete merged flash image first.";
    return;
  }
  const manifest = customManifest([part(file, 0)], "OpenHaldex S3 (merged image)");
  const manifestUrl = trackObjectUrl(manifest);
  installButton.manifest = manifestUrl;
  installButton.setAttribute("manifest", manifestUrl);
  status.textContent = `Merged image ready: ${file.name}`;
});

window.addEventListener("beforeunload", clearObjectUrls);
