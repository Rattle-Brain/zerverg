// zerverg :: default "terminal" snippet
//
// Small touches that show what snippets are for:
//   - a blinking block cursor after the site title
//   - "copy" buttons on code blocks
//   - press "/" anywhere to jump to the search box
//
// Snippets are plain JS files served from /assets/snippets/ and
// loaded with `defer` on every page. Inline scripts are blocked by
// the Content-Security-Policy, so behaviour belongs here.
(function () {
  "use strict";

  function addCursor() {
    var title = document.querySelector(".zv-site-title");
    if (!title || title.querySelector(".zv-cursor")) return;
    var cursor = document.createElement("span");
    cursor.className = "zv-cursor";
    cursor.setAttribute("aria-hidden", "true");
    title.appendChild(cursor);
  }

  function addCopyButtons() {
    if (!navigator.clipboard) return;
    document.querySelectorAll(".zv-main pre").forEach(function (pre) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "zv-copy";
      button.textContent = "copy";
      button.addEventListener("click", function () {
        var code = pre.querySelector("code") || pre;
        navigator.clipboard.writeText(code.innerText).then(function () {
          button.textContent = "copied";
          setTimeout(function () { button.textContent = "copy"; }, 1200);
        });
      });
      pre.appendChild(button);
    });
  }

  function bindSearchKey() {
    document.addEventListener("keydown", function (event) {
      if (event.key !== "/" || event.ctrlKey || event.metaKey) return;
      var target = event.target;
      if (target.closest && target.closest("input, textarea")) return;
      var input = document.querySelector(".zv-search input");
      if (!input) return;
      event.preventDefault();
      input.focus();
    });
  }

  addCursor();
  addCopyButtons();
  bindSearchKey();
})();
