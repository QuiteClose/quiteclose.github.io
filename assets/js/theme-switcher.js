(function () {
  "use strict";

  var STORAGE_SCHEME = "theme-scheme";
  var STORAGE_MODE = "theme-mode";

  var config = null;
  var ready = false;

  function detectPreferredMode() {
    if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) {
      return "dark";
    }
    return "light";
  }

  function getSavedScheme() {
    try { return localStorage.getItem(STORAGE_SCHEME); } catch (e) { return null; }
  }

  function getSavedMode() {
    try { return localStorage.getItem(STORAGE_MODE); } catch (e) { return null; }
  }

  function savePreferences(scheme, mode) {
    try {
      localStorage.setItem(STORAGE_SCHEME, scheme);
      localStorage.setItem(STORAGE_MODE, mode);
    } catch (e) { /* storage unavailable */ }
  }

  function applyTheme(scheme, mode) {
    var themeId = scheme + "-" + mode;
    document.body.setAttribute("data-theme", themeId);

    var toggle = document.getElementById("dark-mode-toggle");
    if (toggle) toggle.checked = mode === "dark";

    var options = document.querySelectorAll(".theme-switcher__option");
    for (var i = 0; i < options.length; i++) {
      var pressed = options[i].getAttribute("data-scheme") === scheme &&
                    options[i].getAttribute("data-mode") === mode;
      options[i].setAttribute("aria-pressed", pressed ? "true" : "false");
    }
  }

  function selectTheme(scheme, mode) {
    if (!ready) return;
    savePreferences(scheme, mode);
    applyTheme(scheme, mode);
  }

  function toggleMode() {
    if (!ready) return;
    var current = getSavedMode() || detectPreferredMode();
    var next = current === "dark" ? "light" : "dark";
    var scheme = getSavedScheme() || config.default.scheme;
    selectTheme(scheme, next);
  }

  function toggleDrawer() {
    var switcher = document.getElementById("theme-switcher");
    var btn = document.getElementById("theme-drawer-toggle");
    if (!switcher || !btn) return;

    var isOpen = switcher.getAttribute("data-state") === "open";
    if (isOpen) {
      switcher.removeAttribute("data-state");
      btn.setAttribute("aria-expanded", "false");
    } else {
      switcher.setAttribute("data-state", "open");
      btn.setAttribute("aria-expanded", "true");
    }
  }

  function closeDrawer() {
    var switcher = document.getElementById("theme-switcher");
    var btn = document.getElementById("theme-drawer-toggle");
    if (switcher) switcher.removeAttribute("data-state");
    if (btn) btn.setAttribute("aria-expanded", "false");
  }

  function buildSchemeList(schemes) {
    var list = document.getElementById("theme-list");
    if (!list) return;

    for (var i = 0; i < schemes.length; i++) {
      var s = schemes[i];
      var li = document.createElement("li");
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "theme-switcher__option";
      btn.setAttribute("data-scheme", s.scheme);
      btn.setAttribute("data-mode", s.mode);
      btn.setAttribute("aria-pressed", "false");
      btn.textContent = s.label;
      btn.addEventListener("click", (function (scheme, mode) {
        return function () { selectTheme(scheme, mode); };
      })(s.scheme, s.mode));
      li.appendChild(btn);
      list.appendChild(li);
    }
  }

  function handleClickOutside(e) {
    var switcher = document.getElementById("theme-switcher");
    if (switcher && !switcher.contains(e.target)) {
      closeDrawer();
    }
  }

  function handleMediaChange(e) {
    var savedMode = getSavedMode();
    if (!savedMode) {
      var scheme = getSavedScheme() || config.default.scheme;
      applyTheme(scheme, e.matches ? "dark" : "light");
    }
  }

  function enableTransitions() {
    setTimeout(function () {
      document.body.classList.add("colors-loaded");
    }, 100);
  }

  function init() {
    var savedScheme = getSavedScheme();
    var savedMode = getSavedMode();

    if (savedScheme) {
      var mode = savedMode || detectPreferredMode();
      document.body.setAttribute("data-theme", savedScheme + "-" + mode);
    }

    var toggle = document.getElementById("dark-mode-toggle");
    if (toggle) {
      toggle.addEventListener("change", toggleMode);
      if (savedMode) toggle.checked = savedMode === "dark";
    }

    document.addEventListener("click", handleClickOutside);

    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeDrawer();
    });

    if (window.matchMedia) {
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", handleMediaChange);
    }

    var drawerBtn = document.getElementById("theme-drawer-toggle");
    if (drawerBtn) {
      drawerBtn.addEventListener("click", toggleDrawer);
    }

    fetch("/js/default.js")
      .then(function (r) { return r.text(); })
      .then(function (text) {
        var match = text.match(/export default\s*(\{[\s\S]*\})\s*;?\s*$/);
        if (!match) return;
        config = new Function("return " + match[1])();
        buildSchemeList(config.schemes);
        var scheme = savedScheme || config.default.scheme;
        var mode = savedMode || detectPreferredMode();
        applyTheme(scheme, mode);
        ready = true;
        enableTransitions();
      });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
