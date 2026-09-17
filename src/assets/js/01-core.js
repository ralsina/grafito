// grafito frontend — core
// Base path resolution and the VIEWS registry: the single
// // source of truth for which views exist, how they open and close,
// // their minimap kind, URL persistence and restore.
//
// All modules under js/ are concatenated into one script (see the
// Makefile), not loaded as separate <script> tags or ES modules, so
// a single "use strict" here (the first statement of the bundle)
// puts the whole thing in strict mode: it catches accidental
// implicit globals (assigning to an undeclared name) and a few
// other footguns without requiring every module to be wrapped in
// its own IIFE, which would break the cross-module references
// (e.g. VIEWS below reads dashboardQueryParams from 05-views.js)
// that rely on whole-script function hoisting.
"use strict";

// Get base path from data attribute (set by BakedFileHandler for deployment flexibility),
// falling back to the path the page itself was served from, so that
// deployments under a base path (e.g. /grafito) work without config.
const pagePath = window.location.pathname.replace(/\/+$/, "");
const basePath = document.body.dataset.basePath || pagePath;

// Shared clipboard helper: writes text to the clipboard and reports
// success/failure through callbacks, falling back to a manual-copy
// alert where the Clipboard API is unavailable (non-secure
// contexts). Centralizes the copy-then-flash-the-button pattern
// used by the AI panel, the log rows and the shareable-link button.
function copyToClipboard(text, options) {
  options = options || {};
  const manualFallbackLabel = options.manualFallbackLabel || "Copy the text manually";
  if (window.isSecureContext && navigator.clipboard) {
    navigator.clipboard
      .writeText(text)
      .then(function () {
        if (options.onSuccess) options.onSuccess();
      })
      .catch(function (err) {
        if (options.onError) {
          options.onError(err);
        } else {
          alert("Failed to copy: " + err.message);
        }
      });
  } else {
    alert(manualFallbackLabel + ":\n\n" + text);
  }
}

// Flashes a button's innerHTML with a checkmark + label for a couple
// of seconds, then restores the original content.
function flashButtonLabel(button, flashHtml, durationMs) {
  if (!button) return;
  const original = button.innerHTML;
  button.innerHTML = flashHtml;
  setTimeout(function () {
    button.innerHTML = original;
  }, durationMs || 2000);
}

// Flashes an icon-only button's material-icons glyph, then restores
// the original glyph. Used for row actions where there is no label
// to swap.
function flashButtonIcon(button, flashText, revertText, durationMs) {
  const icon = button ? button.querySelector(".material-icons") : null;
  if (!icon) return;
  icon.textContent = flashText;
  setTimeout(function () {
    icon.textContent = revertText;
  }, durationMs || 1500);
}

// Helper to build URLs with proper base path handling
function buildUrl(path) {
  if (basePath === "" || basePath === "/") {
    return "/" + path;
  } else {
    return basePath + "/" + path;
  }
}

// --- VIEW REGISTRY ---
// Adding a view touches exactly four places:
//   1. a fragment route in a backend module (each view module has
//      a register_routes method called from
//      Grafito.register_routes),
//   2. a <div id="...-view" hidden hx-get=... hx-trigger=...>
//      inside <main> (or reuse #results for a pure log stream),
//   3. a button with data-view-mode in the #brand-switcher,
//   4. one entry in this registry.
// Mutual exclusion, the switcher highlight, URL persistence and
// restore, and the on-demand fetch are all generic below.
const VIEWS = {
  logs: { minimap: "log" },
  dashboard: {
    element: "dashboard-view",
    endpoint: "dashboard",
    minimap: "services",
    query: dashboardQueryParams,
    urlState: function (params, view) {
      if (view.dataset.unit) params.set("dash_unit", view.dataset.unit);
      if (view.dataset.since) params.set("dash_since", view.dataset.since);
      if (view.dataset.sortBy) {
        params.set("dash_sort_by", view.dataset.sortBy);
        params.set("dash_sort_order", view.dataset.sortOrder || "asc");
      }
    },
    restore: function (params) {
      const view = document.getElementById("dashboard-view");
      const filter = document.getElementById("dashboard-unit-filter");
      if (!view || !filter) return false;
      const unit = params.get("dash_unit");
      if (unit) {
        view.dataset.unit = unit;
        filter.value = unit;
      }
      const since = params.get("dash_since");
      if (since) view.dataset.since = since;
      const sortBy = params.get("dash_sort_by");
      if (sortBy) {
        view.dataset.sortBy = sortBy;
        view.dataset.sortOrder = params.get("dash_sort_order") || "asc";
      }
      return true;
    },
  },
  compose: { element: "compose-view", endpoint: "compose", minimap: null },
  homepage: {
    element: "homepage-view",
    endpoint: "homepage",
    minimap: null,
  },
  processes: {
    element: "processes-view",
    endpoint: "processes",
    minimap: null,
    query: processesQueryParams,
    urlState: function (params, view) {
      if (view.dataset.sortBy) {
        params.set("proc_sort_by", view.dataset.sortBy);
        params.set("proc_sort_order", view.dataset.sortOrder || "desc");
      }
      if (view.dataset.showAll) params.set("proc_limit", "all");
      const filter = document.getElementById("process-filter");
      if (filter && filter.value.trim()) {
        params.set("proc_filter", filter.value.trim());
      }
    },
    restore: function (params) {
      const view = document.getElementById("processes-view");
      const filter = document.getElementById("process-filter");
      if (!view) return false;
      const sortBy = params.get("proc_sort_by");
      if (sortBy) {
        view.dataset.sortBy = sortBy;
        view.dataset.sortOrder = params.get("proc_sort_order") || "desc";
      }
      if (filter && params.get("proc_filter")) {
        filter.value = params.get("proc_filter");
      }
      if (params.get("proc_limit") === "all") {
        view.dataset.showAll = "1";
      }
      return true;
    },
  },
};

// The view currently on screen; "logs" when no other view is.
function currentViewMode() {
  for (const name of Object.keys(VIEWS)) {
    const config = VIEWS[name];
    if (!config.element) continue;
    const element = document.getElementById(config.element);
    if (element && !element.hidden) return name;
  }
  return "logs";
}

function updateViewSwitcher() {
  const mode = currentViewMode();
  document
    .querySelectorAll("#brand-switcher button[data-view-mode]")
    .forEach(function (button) {
      const active = button.dataset.viewMode === mode;
      button.classList.toggle("active", active);
      button.setAttribute("aria-pressed", active ? "true" : "false");
    });
}

// The rail's content differs per view (log severities, unit
// states); views without a minimap hide the rail entirely so no
// stale ticks from another view linger there.
function updateMinimapForView(view) {
  const config = VIEWS[view] || {};
  document.body.classList.toggle("minimap-hidden", !config.minimap);
  if (config.minimap === "log") restoreLogsMinimap();
}

// The one function every caller uses to show or hide a view.
// Opening a view hides every other one; closing the last open
// view returns to the log stream.
function setViewVisible(view, visible, options) {
  options = options || {};
  const config = VIEWS[view];
  if (!config) return;
  const results = document.getElementById("results");
  const element = config.element
    ? document.getElementById(config.element)
    : null;
  if (!results || (view !== "logs" && !element)) return;

  if (!visible) {
    if (element) element.hidden = true;
    const open = currentViewMode();
    if (open === "logs") {
      results.hidden = false;
      delete document.body.dataset.view;
    } else {
      document.body.dataset.view = open;
    }
    updateMinimapForView(open);
    updateViewSwitcher();
    if (!options.skipUrlUpdate) updateBrowserURL();
    return;
  }

  Object.keys(VIEWS).forEach(function (other) {
    if (other === view || !VIEWS[other].element) return;
    const otherElement = document.getElementById(VIEWS[other].element);
    if (otherElement) otherElement.hidden = true;
  });
  if (element) element.hidden = false;
  results.hidden = view !== "logs";
  if (view === "logs") {
    delete document.body.dataset.view;
  } else {
    document.body.dataset.view = view;
  }
  updateMinimapForView(view);
  updateViewSwitcher();
  if (!options.skipUrlUpdate) updateBrowserURL();
  if (config.endpoint) {
    // Some views take a while on open (compose shells out to
    // docker), so the global loading overlay shows until the
    // fragment arrives. Polls never trigger this.
    const spinner = document.getElementById("loading-spinner");
    if (spinner) spinner.classList.add("htmx-request");
    htmx
      .ajax(
        "GET",
        buildUrl(config.endpoint) + (config.query ? config.query() : ""),
        { target: "#" + config.element, swap: "innerHTML" },
      )
      .catch(function () {
        if (element) {
          element.innerHTML =
            '<p style="padding: 1em">Failed to load this view. Is the server still running?</p>';
        }
      })
      .finally(function () {
        if (spinner) spinner.classList.remove("htmx-request");
      });
  }
}

function closeAllViews(options) {
  Object.keys(VIEWS).forEach(function (name) {
    if (name !== "logs") setViewVisible(name, false, options);
  });
}

function setViewMode(mode) {
  if (mode !== "logs" && !VIEWS[mode]) return;
  // The side panel shows content that belongs to the view which
  // opened it (a log entry, the app store, a process); switching
  // views would leave that stale content floating over the new one.
  if (window.closeLogPanel) closeLogPanel();
  Object.keys(VIEWS).forEach(function (name) {
    if (name !== mode) {
      setViewVisible(name, false, { skipUrlUpdate: true });
    }
  });
  setViewVisible(mode, true);
  // The SSE live tail must not keep streaming (and keep a journalctl
  // follower alive on the server) while another view is on screen;
  // refreshLiveStream restarts it when logs become active again.
  if (typeof refreshLiveStream === "function") refreshLiveStream();
}

const viewSwitcher = document.getElementById("brand-switcher");
if (viewSwitcher) {
  viewSwitcher.addEventListener("click", function (event) {
    const button = event.target.closest("button[data-view-mode]");
    if (button) setViewMode(button.dataset.viewMode);
  });
}
