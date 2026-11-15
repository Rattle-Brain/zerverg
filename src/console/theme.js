// Applies the console's saved light/dark choice before the first
// paint (loaded without `defer`), so the page never flashes. The
// toggle button in core.js changes it.
"use strict";
(function () {
  try {
    const saved = localStorage.getItem("zv-console-theme");
    if (saved === "light" || saved === "dark") {
      document.documentElement.dataset.theme = saved;
    }
  } catch (_) {
    // Storage blocked: follow the system setting.
  }
})();
