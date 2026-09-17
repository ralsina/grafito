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
// grafito frontend — filters
// Shared filter configuration (SHARED_FILTER_CONFIGS) consumed by
// // the search omnibox, the stats strip and the URL builder.

// --- Shared Configuration for Filters ---
const SHARED_FILTER_CONFIGS = [
  { id: "search-box", param: "q", type: "value" },
  { id: "unit-filter", param: "unit", type: "value" },
  { id: "tag-filter", param: "tag", type: "value" },
  { id: "hostname-filter", param: "hostname", type: "value" },
  { id: "time-range-filter", param: "since", type: "select" },
  { id: "priority-filter", param: "priority", type: "select" },
  {
    id: "live-view",
    param: "live-view",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-timestamp",
    param: "col-visible-timestamp",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-hostname",
    param: "col-visible-hostname",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-unit",
    param: "col-visible-unit",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-tag",
    param: "col-visible-tag",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-priority",
    param: "col-visible-priority",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-message",
    param: "col-visible-message",
    type: "checkbox",
    trueValue: "on",
  },
];
// grafito frontend — init
// DOMContentLoaded init: global htmx error handler, safe markdown
// // renderer, theme switcher, AI provider discovery, column visibility
// // persistence, filter/view URL restore, stats strip and minimap.

document.addEventListener("DOMContentLoaded", function () {
  // --- GLOBAL HTMX ERROR HANDLER ---
  const globalErrorDialog = document.getElementById("global-error-dialog");
  const globalErrorDialogContent = document.getElementById(
    "global-error-dialog-content",
  );

  if (globalErrorDialog && globalErrorDialogContent) {
    // Around page load, htmx occasionally reports a failed request for
    // a transient reason: one network hiccup, or a request aborted
    // because a parent swap replaced the element that sent it. The
    // next poll succeeds milliseconds later, so interrupting the user
    // with a modal dialog for the first failure reads as "the app is
    // broken". A failure only opens the dialog after this grace
    // period expires without any request succeeding; a real outage
    // still surfaces (every failure re-arms the message), while a
    // recovery cancels it. HTTP-level errors (4xx/5xx) skip the grace
    // period: the server answered, so something is genuinely wrong.
    const ERROR_DIALOG_GRACE_MS = 1500;
    let errorDialogTimer = null;
    let pendingErrorText = null;

    function showErrorDialog(errorText) {
      globalErrorDialogContent.innerHTML = `
                <p role="alert" class="inline-alert">
                  <strong>Details:</strong> ${errorText}
                </p>`;
      if (!globalErrorDialog.open) {
        globalErrorDialog.showModal();
      }
    }

    function cancelPendingErrorDialog() {
      if (errorDialogTimer !== null) {
        clearTimeout(errorDialogTimer);
        errorDialogTimer = null;
        pendingErrorText = null;
      }
    }

    document.body.addEventListener("htmx:afterRequest", function (event) {
      if (event.detail.error) {
        console.error("HTMX Request Failed. Details:", event.detail); // For debugging
        pendingErrorText = event.detail.error.message || "Failed to send request";
        if (globalErrorDialog.open) {
          // Already up: refresh the message right away.
          showErrorDialog(pendingErrorText);
        } else if (errorDialogTimer === null) {
          errorDialogTimer = setTimeout(function () {
            errorDialogTimer = null;
            if (pendingErrorText !== null) {
              showErrorDialog(pendingErrorText);
              pendingErrorText = null;
            }
          }, ERROR_DIALOG_GRACE_MS);
        }
      } else if (event.detail.successful) {
        // Any success right after a failure means the failure was a
        // transient hiccup, not an outage: drop the pending dialog.
        cancelPendingErrorDialog();
        pendingErrorText = null;
        if (globalErrorDialog.open) {
          globalErrorDialog.close();
          globalErrorDialogContent.innerHTML = ""; // Clear content
        }

        updateBrowserURL();
      }
    });

    // HTTP error responses (4xx/5xx) fire htmx:responseError, not
    // htmx:afterRequest with an error detail, so handle them here or
    // the user just sees a silently empty results area.
    document.body.addEventListener("htmx:responseError", function (event) {
      // The server answered, so this is not a transient hiccup: show
      // it immediately, dropping any pending network-error dialog so
      // the more specific HTTP message is not overwritten later.
      cancelPendingErrorDialog();
      const status = event.detail.xhr ? event.detail.xhr.status : "?";
      console.error(
        "HTMX Request Failed. Status:",
        status,
        "Details:",
        event.detail,
      );
      let errorText = `Server request failed (HTTP ${status})`;
      showErrorDialog(errorText);
      // If the failed request was meant to fill the results area,
      // show the error inline instead of leaving it blank.
      const target = event.detail.target || event.detail.elt;
      if (target && target.id === "results") {
        target.innerHTML = `
                <p role="alert" class="inline-alert">
                  Failed to load logs (HTTP ${status}). Check the server or adjust the filters, then reload.
                </p>`;
      }
    });
  }
  // --- END GLOBAL HTMX ERROR HANDLER ---

  // --- SAFE MARKDOWN RENDERING ---
  // AI output is untrusted: it echoes log content that can carry
  // prompt injection, and a compromised/misconfigured provider is
  // itself a vector. Parse the markdown, then strip anything
  // executable (raw HTML, script/iframe elements, event handler
  // attributes, javascript: URLs) from the result.
  window.renderSafeMarkdown = function (markdown) {
    if (!window.marked) {
      const pre = document.createElement("pre");
      pre.textContent = markdown || "";
      return pre.outerHTML;
    }
    const tpl = document.createElement("template");
    tpl.innerHTML = marked.parse(markdown || "");
    tpl.content
      .querySelectorAll(
        "script, style, iframe, object, embed, link, meta, base, form, input, button, svg, math",
      )
      .forEach(function (el) {
        el.remove();
      });
    const allowedUri = /^(https?:|mailto:|#|\/(?!\/))/i;
    tpl.content.querySelectorAll("*").forEach(function (el) {
      Array.from(el.attributes).forEach(function (attr) {
        const name = attr.name.toLowerCase();
        const value = (attr.value || "").trim().toLowerCase();
        if (name === "style" || name.startsWith("on")) {
          // style= survives script removal but still allows CSS
          // exfiltration tricks; AI output has no honest use for it.
          el.removeAttribute(attr.name);
        } else if (
          (name === "href" || name === "src" || name === "xlink:href") &&
          value &&
          !allowedUri.test(value) &&
          !value.startsWith("data:image/")
        ) {
          // The negative lookahead also rejects protocol-relative
          // URLs (//evil.com), which browsers resolve as https:.
          el.removeAttribute(attr.name);
        }
      });
    });
    return tpl.innerHTML;
  };
  // --- END SAFE MARKDOWN RENDERING ---

  // --- THEME SWITCHER LOGIC ---
  const themeSwitch = document.getElementById("theme-switch");
  const htmlElement = document.documentElement;

  function applyTheme(theme) {
    if (theme === "dark") {
      htmlElement.setAttribute("data-theme", "dark");
      if (themeSwitch) themeSwitch.checked = true;
    } else {
      htmlElement.setAttribute("data-theme", "light");
      if (themeSwitch) themeSwitch.checked = false;
    }
    localStorage.setItem("theme", theme);
  }

  // Apply initial theme: 1. saved choice, 2. Mission's default.
  // (An explicit user choice beats the default; the OS preference
  // is only honored through that default.)
  const savedTheme = localStorage.getItem("theme");
  if (savedTheme) {
    applyTheme(savedTheme);
  } else {
    applyTheme("dark");
  }

  if (themeSwitch) {
    themeSwitch.addEventListener("change", function () {
      applyTheme(this.checked ? "dark" : "light");
    });
  }
  // --- END THEME SWITCHER LOGIC ---

  // --- AI PROVIDER SECTION ---
  // Use window scope so askAIExplanation can access it
  window.selectedAIProvider =
    localStorage.getItem("grafito-ai-provider") || null;
  window.selectedAIModel = localStorage.getItem("grafito-ai-model") || null;

  // Load models for a specific provider
  function loadAIModels(providerId) {
    const modelSelect = document.getElementById("ai-model-select");
    if (!modelSelect || !providerId) return;

    modelSelect.innerHTML = '<option value="">Loading models...</option>';
    modelSelect.disabled = true;

    fetch(`${buildUrl("ai-models")}?provider=${encodeURIComponent(providerId)}`)
      .then((response) => response.json())
      .then((data) => {
        modelSelect.innerHTML = "";
        modelSelect.disabled = false;

        if (!data.models || data.models.length === 0) {
          modelSelect.innerHTML =
            '<option value="">No models available</option>';
          return;
        }

        // Find saved model or default
        const savedModel = localStorage.getItem(
          `grafito-ai-model-${providerId}`,
        );
        let foundSaved = false;

        data.models.forEach((model) => {
          const option = document.createElement("option");
          option.value = model.id;
          option.textContent = model.name;
          if (savedModel === model.id) {
            option.selected = true;
            foundSaved = true;
            window.selectedAIModel = model.id;
          } else if (!savedModel && model.default) {
            option.selected = true;
            window.selectedAIModel = model.id;
          }
          modelSelect.appendChild(option);
        });

        // If no saved or default found, select first
        if (!foundSaved && !window.selectedAIModel && data.models.length > 0) {
          window.selectedAIModel = data.models[0].id;
          modelSelect.value = window.selectedAIModel;
        }
      })
      .catch((error) => {
        console.error("Failed to load AI models:", error);
        modelSelect.innerHTML = '<option value="">Failed to load</option>';
        modelSelect.disabled = false;
      });
  }

  function loadAIProviders() {
    fetch(buildUrl("ai-providers"))
      .then((response) => response.json())
      .then((data) => {
        const loadingEl = document.getElementById("ai-loading");
        const disabledEl = document.getElementById("ai-disabled");
        const enabledEl = document.getElementById("ai-enabled");
        const selectEl = document.getElementById("ai-provider-select");
        const modelSelect = document.getElementById("ai-model-select");

        if (loadingEl) loadingEl.style.display = "none";

        if (!data.enabled || data.providers.length === 0) {
          if (disabledEl) disabledEl.style.display = "block";
          return;
        }

        if (enabledEl) enabledEl.style.display = "block";

        // Populate provider dropdown
        if (selectEl) {
          selectEl.innerHTML = "";
          data.providers.forEach((provider) => {
            const option = document.createElement("option");
            option.value = provider.id;
            option.textContent = provider.name;
            if (
              window.selectedAIProvider === provider.id ||
              (!window.selectedAIProvider &&
                data.current &&
                data.current.includes(provider.name))
            ) {
              option.selected = true;
              window.selectedAIProvider = provider.id;
            }
            selectEl.appendChild(option);
          });

          // If no selection yet, use first provider
          if (!window.selectedAIProvider && data.providers.length > 0) {
            window.selectedAIProvider = data.providers[0].id;
            selectEl.value = window.selectedAIProvider;
          }

          // Load models for selected provider
          loadAIModels(window.selectedAIProvider);

          // Handle provider change
          selectEl.addEventListener("change", function () {
            window.selectedAIProvider = this.value;
            localStorage.setItem(
              "grafito-ai-provider",
              window.selectedAIProvider,
            );
            window.selectedAIModel = null; // Reset model on provider change
            loadAIModels(window.selectedAIProvider);
          });
        }

        // Handle model change
        if (modelSelect) {
          modelSelect.addEventListener("change", function () {
            window.selectedAIModel = this.value;
            if (window.selectedAIProvider) {
              localStorage.setItem(
                `grafito-ai-model-${window.selectedAIProvider}`,
                window.selectedAIModel,
              );
            }
          });
        }
      })
      .catch((error) => {
        console.error("Failed to load AI providers:", error);
        const loadingEl = document.getElementById("ai-loading");
        if (loadingEl) loadingEl.textContent = "Failed to load providers";
      });
  }

  loadAIProviders();
  // --- END AI PROVIDER SECTION ---

  // --- SERVER INFO (demo banner + default landing view) ---
  // Fake-data (demo site) builds say so in the status bar; real
  // deployments stay quiet. The same tiny payload reports which
  // views the deployment enables, so a bare URL can land on the
  // homepage when it is available. Failure is not fatal: the
  // banner stays hidden and the log stream remains the landing.
  const serverInfoPromise = fetch(buildUrl("server-info"))
    .then((response) => response.json())
    .catch(() => {
      /* no server-info: not fatal */
      return null;
    });
  serverInfoPromise.then((info) => {
    if (info && info.demo) {
      const banner = document.getElementById("demo-banner");
      if (banner) banner.hidden = false;
    }
  });
  // --- END SERVER INFO ---

  // --- COLUMN VISIBILITY PERSISTENCE ---
  const COLUMN_VISIBILITY_CHECKBOX_IDS = [
    "col-visible-timestamp",
    "col-visible-hostname",
    "col-visible-unit",
    "col-visible-tag",
    "col-visible-priority",
    "col-visible-message",
  ];

  COLUMN_VISIBILITY_CHECKBOX_IDS.forEach((id) => {
    const checkbox = document.getElementById(id);
    if (checkbox) {
      const localStorageKey = `grafito-${id}-checked`;
      const savedState = localStorage.getItem(localStorageKey);
      if (savedState !== null) {
        checkbox.checked = savedState === "true";
      }
      checkbox.addEventListener("change", function () {
        localStorage.setItem(localStorageKey, this.checked);
        // HTMX attributes on the checkbox will handle the refresh
      });
    }
  });
  // --- Populate Filters from URL Parameters ---
  const params = new URLSearchParams(window.location.search);
  SHARED_FILTER_CONFIGS.forEach((config) => {
    const element = document.getElementById(config.id);
    if (params.has(config.param) && element) {
      const paramValue = params.get(config.param);
      if (config.type === "value") {
        element.value = paramValue;
      } else if (config.type === "select") {
        if (
          Array.from(element.options).some((opt) => opt.value === paramValue)
        ) {
          element.value = paramValue;
        }
      } else if (config.type === "checkbox") {
        // Checkboxes are only present in the URL when checked (e.g. live-view=on).
        element.checked = params.get(config.param) === config.trueValue;
      }
    }
  });

  // --- Restore View from URL Parameters ---
  // A reload (or shared link) with view=<name> reopens that view;
  // each view's restore() re-applies its saved state first. The bare
  // URL (no view=) lands on the homepage when the deployment enables
  // it, falling back to the log stream otherwise.
  const requestedView = params.get("view");
  if (requestedView && VIEWS[requestedView]) {
    // Views with state re-apply it first; stateless views (like
    // compose) just open.
    if (!VIEWS[requestedView].restore || VIEWS[requestedView].restore(params)) {
      setViewVisible(requestedView, true);
    }
  } else {
    serverInfoPromise.then((info) => {
      const views = info && info.views;
      if (views && views.homepage === false) return; // stay on logs
      setViewMode("homepage");
    });
  }

  updateViewSwitcher();

  // Clear All Filters Button Functionality
  const clearFiltersButton = document.getElementById("clear-filters-btn");
  if (clearFiltersButton) {
    clearFiltersButton.addEventListener("click", function () {
      // Reset text inputs
      document.getElementById("search-box").value = "";
      document.getElementById("unit-filter").value = "";
      document.getElementById("tag-filter").value = "";
      document.getElementById("hostname-filter").value = "";

      // Reset select elements to their default values
      document.getElementById("time-range-filter").value = ""; // "Any time"
      document.getElementById("priority-filter").value = "5"; // "Notice"

      // Reset checkbox
      const liveViewCheckbox = document.getElementById("live-view");
      if (liveViewCheckbox.checked) {
        liveViewCheckbox.checked = false;
        // Manually trigger change for HTMX if live view was active
        htmx.trigger(liveViewCheckbox, "change");
      }
      htmx.trigger(document.body, "initial-load-event", {}); // Reload logs
      updateBrowserURL(); // Update URL after clearing filters
    });
  }

  // Live toggle: refresh immediately when switched on or off
  const liveViewInput = document.getElementById("live-view");
  if (liveViewInput) {
    liveViewInput.addEventListener("change", function () {
      htmx.trigger(document.body, "live-poll");
    });
  }

  // --- STATS STRIP + MINIMAP ---
  // Both are computed client-side from the rendered table, so they
  // stay in sync with whatever the server sent (filters, sorting…).
  function updateStatsAndMinimap() {
    const rows = document.querySelectorAll(
      "#results table tbody tr.log-row-hover-actions",
    );
    let total = rows.length;
    let errors = 0;
    let warnings = 0;
    const unitCounts = new Map();

    rows.forEach((row) => {
      for (let priority = 0; priority <= 7; priority++) {
        if (!row.classList.contains(`priority-${priority}`)) continue;
        if (priority <= 3) errors++;
        else if (priority === 4) warnings++;
        break;
      }
      const unitCell = row.querySelector("td.log-unit-cell");
      if (unitCell) {
        const unitName = unitCell.textContent.trim();
        unitCounts.set(unitName, (unitCounts.get(unitName) || 0) + 1);
      }
    });

    const countMessage = document.querySelector("#results .results-count");
    const totalEl = document.getElementById("stat-total");
    if (totalEl) {
      totalEl.textContent = total.toLocaleString();
      totalEl.title = countMessage ? countMessage.textContent.trim() : "";
    }
    const errorsEl = document.getElementById("stat-errors");
    if (errorsEl) errorsEl.textContent = errors.toLocaleString();
    const warningsEl = document.getElementById("stat-warnings");
    if (warningsEl) warningsEl.textContent = warnings.toLocaleString();
    const unitsEl = document.getElementById("stat-units");
    if (unitsEl) unitsEl.textContent = unitCounts.size.toLocaleString();

    let noisiestUnit = "–";
    let noisiestCount = 0;
    unitCounts.forEach((count, unitName) => {
      if (count > noisiestCount) {
        noisiestCount = count;
        noisiestUnit = unitName;
      }
    });
    const noisiestEl = document.getElementById("stat-noisiest");
    if (noisiestEl) {
      noisiestEl.textContent = noisiestUnit;
      noisiestEl.title =
        noisiestCount > 0
          ? `${noisiestCount} entries in view`
          : "No units in view";
    }

    // Minimap: one tick per row (sampled), colored by severity.
    // Ticks carry enough data to preview the entry on hover and to
    // scroll to it on click.
    const track = document.getElementById("minimap-track");
    if (track) {
      track.innerHTML = "";
      const maxTicks = 240;
      const step = Math.max(1, Math.ceil(total / maxTicks));
      for (let index = 0; index < total; index += step) {
        const row = rows[index];
        const tick = document.createElement("i");
        tick.dataset.rowIndex = String(index);
        for (let priority = 0; priority <= 7; priority++) {
          if (row.classList.contains(`priority-${priority}`)) {
            tick.dataset.priority = priority;
            break;
          }
        }
        const timestampCell = row.querySelector("td.log-timestamp-cell");
        const priorityCell = row.querySelector("td.log-priority-cell .tag");
        const messageCell = row.querySelector("td.log-message-cell");
        tick.dataset.ts = timestampCell ? timestampCell.textContent.trim() : "";
        tick.dataset.pri = priorityCell ? priorityCell.textContent.trim() : "";
        tick.dataset.msg = messageCell
          ? messageCell.textContent.trim().slice(0, 140)
          : "";
        track.appendChild(tick);
      }
    }
  }

  document.body.addEventListener("htmx:afterSwap", function (event) {
    if (event.detail.target && event.detail.target.id === "results") {
      updateStatsAndMinimap();
    }
  });
  // The log minimap builder lives in this closure; expose it so
  // the dashboard code can restore the log view when leaving.
  window.updateStatsAndMinimap = updateStatsAndMinimap;

  // --- Minimap interaction: hover previews, click jumps ---
  const minimapTop = document.getElementById("minimap-top");
  if (minimapTop) {
    minimapTop.addEventListener("click", function () {
      const stream = document.getElementById("stream");
      if (stream) {
        stream.scrollTo({ top: 0, behavior: "smooth" });
      }
    });
  }

  const minimapTrack = document.getElementById("minimap-track");
  const minimapTooltip = document.createElement("div");
  minimapTooltip.id = "minimap-tooltip";
  minimapTooltip.hidden = true;
  document.body.appendChild(minimapTooltip);

  function hideMinimapTooltip() {
    minimapTooltip.hidden = true;
  }

  if (minimapTrack) {
    minimapTrack.addEventListener("mouseover", function (event) {
      const tick = event.target.closest("i");
      if (!tick || !tick.dataset.ts) return;
      minimapTooltip.innerHTML =
        `<div class="minimap-tip-time">${tick.dataset.ts}` +
        ` · ${tick.dataset.pri}</div>` +
        `<div class="minimap-tip-msg"></div>`;
      minimapTooltip.querySelector(".minimap-tip-msg").textContent =
        tick.dataset.msg;
      minimapTooltip.hidden = false;
      const rect = tick.getBoundingClientRect();
      const top = Math.min(
        Math.max(rect.top + rect.height / 2 - 20, 8),
        window.innerHeight - 70,
      );
      minimapTooltip.style.top = `${top}px`;
      minimapTooltip.style.right = `${window.innerWidth - rect.left + 10}px`;
    });
    minimapTrack.addEventListener("mouseleave", hideMinimapTooltip);

    minimapTrack.addEventListener("click", function (event) {
      const tick = event.target.closest("i");
      if (!tick) return;
      const index = Number(tick.dataset.rowIndex || 0);
      // The same rail serves both views: log severities and, in
      // dashboard view, unit states.
      const rowSelector =
        document.body.dataset.view === "dashboard"
          ? "#dashboard-view tbody tr"
          : "#results table tbody tr.log-row-hover-actions";
      const row = document.querySelectorAll(rowSelector)[index];
      if (!row) return;
      row.scrollIntoView({ behavior: "smooth", block: "center" });
      row.classList.remove("row-flash");
      // Restart the flash animation if the row is clicked twice
      void row.offsetWidth;
      row.classList.add("row-flash");
      setTimeout(function () {
        row.classList.remove("row-flash");
      }, 1300);
    });
  }
  // --- MINIMAP VIEWPORT WINDOW ---
  // A scrollbar-thumb style window over the ticks showing which
  // slice of the rows is currently on screen. The tick builders
  // rebuild the track's children, so a mutation observer keeps
  // the window element alive in there.
  function ensureMinimapWindow() {
    if (!minimapTrack) return null;
    let win = document.getElementById("minimap-window");
    if (!win || win.parentElement !== minimapTrack) {
      win = document.createElement("div");
      win.id = "minimap-window";
      win.hidden = true;
      minimapTrack.appendChild(win);
    }
    return win;
  }

  const streamEl = document.getElementById("stream");

  function updateMinimapWindow() {
    const win = ensureMinimapWindow();
    if (!win) return;
    if (!streamEl || document.body.classList.contains("minimap-hidden")) {
      win.hidden = true;
      return;
    }
    const scrollable = streamEl.scrollHeight - streamEl.clientHeight;
    if (scrollable <= 1) {
      win.hidden = true;
      return;
    }
    const top = streamEl.scrollTop / streamEl.scrollHeight;
    const visible = streamEl.clientHeight / streamEl.scrollHeight;
    win.hidden = false;
    win.style.top = (top * 100).toFixed(3) + "%";
    win.style.height = Math.max(visible * 100, 2).toFixed(3) + "%";
  }

  if (streamEl) {
    streamEl.addEventListener("scroll", updateMinimapWindow, {
      passive: true,
    });
    if (window.ResizeObserver) {
      new ResizeObserver(updateMinimapWindow).observe(streamEl);
    }
  }
  window.addEventListener("resize", updateMinimapWindow);
  if (minimapTrack) {
    new MutationObserver(updateMinimapWindow).observe(minimapTrack, {
      childList: true,
    });
    updateMinimapWindow();
  }
  // --- END MINIMAP VIEWPORT WINDOW ---
  // --- END MINIMAP INTERACTION ---
  // --- END STATS STRIP + MINIMAP ---
});
// grafito frontend — filters runtime
// Filter URL building, the omnibox tokenizer and cross-view
// // jumps (setUnitFilterAndTrigger).

// Helper function to build URLSearchParams from current filters.
// `options.exclude` skips listed params (used by the plain-text
// export, where a live-tail flag makes no sense).
function buildFilterURLSearchParams(options) {
  options = options || {};
  const exclude = options.exclude || [];
  const params = new URLSearchParams();
  SHARED_FILTER_CONFIGS.forEach((config) => {
    if (exclude.includes(config.param)) return;
    const element = document.getElementById(config.id);
    if (element) {
      if (config.type === "checkbox") {
        if (element.checked) {
          // Use element.value if available (usually "on" for checkboxes), otherwise config.trueValue
          params.set(config.param, element.value || config.trueValue);
        }
        // If unchecked, the parameter is simply not added.
        // This works with server-side `has_key?` logic.
      } else if (element.value) {
        // For text inputs and selects.
        params.set(config.param, element.value);
      }
    }
  });
  return params;
}

// --- Omnibox tokenizer ---
// The DataDog trick: typing `unit:foo`, `tag:foo`, `hostname:foo` or
// `prio:foo` in the search box and pressing space or enter turns the
// word into the matching filter control (visible as a chip in the
// omnibox) instead of grepping log messages for it.
const OMNIBOX_FILTER_KEYS = {
  unit: { id: "unit-filter", trigger: "immediateUnitFilterUpdate" },
  tag: { id: "tag-filter", trigger: "immediateTagFilterUpdate" },
  hostname: {
    id: "hostname-filter",
    trigger: "immediateHostnameFilterUpdate",
  },
  prio: { id: "priority-filter", trigger: "change" },
  priority: { id: "priority-filter", trigger: "change" },
};

const PRIORITY_NAME_TO_VALUE = {
  emerg: "0",
  emergency: "0",
  alert: "1",
  crit: "2",
  critical: "2",
  err: "3",
  error: "3",
  warn: "4",
  warning: "4",
  notice: "5",
  info: "6",
  debug: "7",
};

function tokenizeOmnibox() {
  const searchBox = document.getElementById("search-box");
  if (!searchBox) return;
  const words = searchBox.value.split(/\s+/);
  const remaining = [];
  const tokens = [];
  words.forEach(function (word) {
    const separator = word.indexOf(":");
    const key = separator > 0 ? word.slice(0, separator).toLowerCase() : "";
    const value = separator > 0 ? word.slice(separator + 1).trim() : "";
    const config = OMNIBOX_FILTER_KEYS[key];
    if (config && value && document.getElementById(config.id)) {
      tokens.push([config, value]);
    } else if (word) {
      remaining.push(word);
    }
  });
  if (tokens.length === 0) return;
  // Rewrite the search box before applying the tokens: the immediate
  // triggers snapshot the included filter values, and the query must
  // not still contain the token words at that moment.
  searchBox.value = remaining.join(" ");
  tokens.forEach(function (token) {
    const config = token[0];
    const filter = document.getElementById(config.id);
    filter.value =
      config.id === "priority-filter"
        ? PRIORITY_NAME_TO_VALUE[token[1]] || token[1]
        : token[1];
    htmx.trigger(filter, config.trigger);
  });
  renderActiveFilterChips();
}

const searchBox = document.getElementById("search-box");
if (searchBox) {
  searchBox.addEventListener("keydown", function (event) {
    if (event.key === " " || event.key === "Enter") {
      tokenizeOmnibox();
    }
  });
}

function renderActiveFilterChips() {
  const container = document.getElementById("active-filters");
  if (!container) return;
  container.innerHTML = "";
  [
    ["unit-filter", "unit", "immediateUnitFilterUpdate"],
    ["tag-filter", "tag", "immediateTagFilterUpdate"],
    ["hostname-filter", "hostname", "immediateHostnameFilterUpdate"],
  ].forEach(function (config) {
    const input = document.getElementById(config[0]);
    const value = (input?.value || "").trim();
    if (!value) return;
    const chip = document.createElement("span");
    chip.className = "af-chip";
    const labelText = document.createElement("span");
    labelText.className = "af-chip-label";
    labelText.textContent = config[1] + ": " + value;
    const remove = document.createElement("button");
    remove.className = "af-chip-x";
    remove.type = "button";
    remove.title = "Remove this filter";
    remove.setAttribute("aria-label", "Remove " + config[1] + " filter");
    remove.textContent = "✕";
    remove.addEventListener("click", function () {
      input.value = "";
      // Use the input's dedicated immediate trigger: the plain "input"
      // event's `changed` filter can suppress the refetch when the
      // filter was set programmatically (e.g. clicking a unit link).
      htmx.trigger(input, config[2]);
      renderActiveFilterChips();
    });
    chip.append(labelText, remove);
    container.appendChild(chip);
  });
}

function updateBrowserURL() {
  const params = buildFilterURLSearchParams();
  // Persist the active view and its state so reloads and
  // shared links land back where the user was. The homepage is
  // the root view: it owns the bare URL, so it is the one view
  // never written into it (and the landing for a URL without
  // a view= parameter).
  const mode = currentViewMode();
  if (mode !== "homepage") {
    params.set("view", mode);
    const config = VIEWS[mode];
    const element = config.element
      ? document.getElementById(config.element)
      : null;
    if (config.urlState && element) config.urlState(params, element);
  }
  renderActiveFilterChips();

  let queryString = params.toString();
  const newUrl = queryString
    ? window.location.origin + window.location.pathname + "?" + queryString
    : window.location.origin + window.location.pathname; // Clean URL if no params
  window.history.replaceState({ path: newUrl }, "", newUrl);
}

function copyShareableLink() {
  const params = buildFilterURLSearchParams();
  const shareUrl =
    window.location.origin + window.location.pathname + "?" + params.toString();

  copyToClipboard(shareUrl, {
    manualFallbackLabel: "Shareable Link (copy manually)",
    onSuccess: function () {
      alert("Link copied to clipboard!");
    },
  });
}

function exportLogsAsText() {
  // The 'live-view' parameter is not relevant for a static export.
  const params = buildFilterURLSearchParams({ exclude: ["live-view"] });
  params.set("format", "text"); // Specify text format for the export

  const exportUrl = buildUrl("logs") + "?" + params.toString();

  const tempLink = document.createElement("a");
  tempLink.href = exportUrl;
  tempLink.setAttribute("download", "grafito-logs.txt"); // Suggested filename
  document.body.appendChild(tempLink); // Append to body (needed for Firefox)
  tempLink.click(); // Programmatically click the link to trigger download
  document.body.removeChild(tempLink); // Clean up the temporary link
}

function setUnitFilterAndTrigger(unitName) {
  // Coming from the dashboard or the compose view (a table link or
  // the sidebar's "view logs" call): switch back to the log stream
  // and close the sidebar, which has served its purpose.
  closeAllViews({ skipUrlUpdate: true });
  if (window.closeLogPanel) {
    closeLogPanel();
  }
  const unitFilterInput = document.getElementById("unit-filter");
  if (unitFilterInput) {
    unitFilterInput.value = unitName;
    // Trigger a custom event that is configured for immediate HTMX requests
    htmx.trigger(unitFilterInput, "immediateUnitFilterUpdate");
  }
  return false; // Prevent default anchor link behavior
}
// grafito frontend — per-view helpers
// View wrappers, process table sort/limit, process panel log
// // jumps, dashboard sorting and the services minimap.

// --- PROCESS TABLE SORTING + FILTER ---
// Like the dashboard, the current sort lives in #processes-view's
// dataset so the polls and reopening preserve it; the filter
// text lives in the topbar input.
function processesQueryParams() {
  const view = document.getElementById("processes-view");
  if (!view) return "";
  const params = new URLSearchParams();
  if (view.dataset.sortBy) params.set("sort_by", view.dataset.sortBy);
  if (view.dataset.sortOrder) params.set("sort_order", view.dataset.sortOrder);
  if (view.dataset.showAll) params.set("limit", "all");
  const filterInput = document.getElementById("process-filter");
  if (filterInput && filterInput.value.trim()) {
    params.set("filter", filterInput.value.trim());
  }
  const qs = params.toString();
  return qs ? "?" + qs : "";
}

// Toggle between the capped table (top 100 rows, cheap to poll)
// and the full list; the choice rides the URL like the rest of
// the process view state.
function setProcessLimit(showAll) {
  const view = document.getElementById("processes-view");
  if (!view) return false;
  if (showAll) {
    view.dataset.showAll = "1";
  } else {
    delete view.dataset.showAll;
  }
  updateProcessesPollUrl();
  updateBrowserURL();
  htmx.ajax("GET", buildUrl("processes") + processesQueryParams(), {
    target: "#processes-view",
    swap: "morph:innerHTML",
  });
  return false;
}

function updateProcessesPollUrl() {
  const view = document.getElementById("processes-view");
  if (view) {
    view.setAttribute("hx-get", "processes" + processesQueryParams());
  }
}

function sortProcesses(sortBy) {
  const view = document.getElementById("processes-view");
  if (!view) return;
  // Flip direction when re-clicking the active column; numeric
  // columns start descending (biggest first), text columns asc.
  const textColumns = ["pid", "user", "state", "cmd"];
  if (view.dataset.sortBy === sortBy) {
    view.dataset.sortOrder = view.dataset.sortOrder === "asc" ? "desc" : "asc";
  } else {
    view.dataset.sortBy = sortBy;
    view.dataset.sortOrder = textColumns.includes(sortBy) ? "asc" : "desc";
  }
  updateProcessesPollUrl();
  updateBrowserURL();
  htmx.ajax("GET", buildUrl("processes") + processesQueryParams(), {
    target: "#processes-view",
    swap: "innerHTML",
  });
}

// --- PROCESS PANEL: VIEW LOGS ---
// From the process detail panel: jump into the journal. A
// systemd-managed process filters by its unit; anything else
// falls back to a text search for the command name.
function setProcessLogsFilter(unitName, commandName) {
  if (unitName) {
    return setUnitFilterAndTrigger(unitName);
  }
  if (window.closeLogPanel) {
    closeLogPanel();
  }
  closeAllViews({ skipUrlUpdate: true });
  const searchBox = document.getElementById("search-box");
  if (searchBox) {
    searchBox.value = commandName;
    // initial-load-event refetches the logs with every
    // .log-filter, including the search box (q=).
    htmx.trigger(document.body, "initial-load-event", {});
    updateBrowserURL();
  }
  return false;
}

// From the process detail panel: jump to the compose view and open
// the owning service's detail panel. The attribution comes from the
// process snapshot's cgroup join (#91/#92).
function openComposeService(stack, service) {
  setViewMode("compose");
  htmx.ajax(
    "GET",
    buildUrl("compose-details") + "?stack=" + encodeURIComponent(stack) + "&service=" + encodeURIComponent(service),
    { target: "#panel-detail-content", swap: "innerHTML" },
  );
  showLogPanel("detail");
  return false;
}
window.openComposeService = openComposeService;

// --- DASHBOARD SORTING + FILTERS ---
// The unit table sorting, the service filter and the time window
// are all applied server-side; the current values are kept in
// #dashboard-view's dataset so the 30s auto-refresh polls (and
// reopening the dashboard) preserve them.
function dashboardQueryParams() {
  const view = document.getElementById("dashboard-view");
  if (!view) return "";
  const params = new URLSearchParams();
  if (view.dataset.sortBy) params.set("sort_by", view.dataset.sortBy);
  if (view.dataset.sortOrder) params.set("sort_order", view.dataset.sortOrder);
  if (view.dataset.unit) params.set("unit", view.dataset.unit);
  if (view.dataset.since) params.set("since", view.dataset.since);
  const qs = params.toString();
  return qs ? "?" + qs : "";
}

function updateDashboardPollUrl() {
  const view = document.getElementById("dashboard-view");
  if (view) {
    view.setAttribute("hx-get", "dashboard" + dashboardQueryParams());
  }
}

// Syncs the dataset from the current control values, so the poll
// URL always reflects what the user currently sees. The service
// filter lives in the topbar (outside the swapped fragment); the
// time window select is part of the fragment.
function syncDashboardStateFromFragment() {
  const view = document.getElementById("dashboard-view");
  if (!view) return;
  const unitInput = document.getElementById("dashboard-unit-filter");
  const sinceSelect = view.querySelector('select[name="since"]');
  if (unitInput) view.dataset.unit = unitInput.value.trim();
  if (sinceSelect) view.dataset.since = sinceSelect.value;
  updateDashboardPollUrl();
}

function sortDashboard(sortBy) {
  const view = document.getElementById("dashboard-view");
  if (!view) return;
  // Clicking the active column flips the direction; a new column
  // starts ascending.
  const flip =
    view.dataset.sortBy === sortBy &&
    (view.dataset.sortOrder || "asc") === "asc";
  view.dataset.sortBy = sortBy;
  view.dataset.sortOrder = flip ? "desc" : "asc";
  updateDashboardPollUrl();
  htmx.ajax("GET", buildUrl("dashboard") + dashboardQueryParams(), {
    target: "#dashboard-view",
    swap: "innerHTML",
  });
}

// --- DASHBOARD SERVICES MINIMAP ---
// In dashboard view the same rail that shows log severities shows
// one tick per unit row, colored by state (mapped onto the log
// severity palette: failed=error red, activating=warning amber,
// active=notice green, inactive=debug gray). Ticks carry the
// hover-preview data and click-to-scroll, like the log minimap.
function buildServicesMinimap() {
  const track = document.getElementById("minimap-track");
  if (!track) return;
  const rows = document.querySelectorAll("#dashboard-view tbody tr");
  track.innerHTML = "";
  const maxTicks = 240;
  const step = Math.max(1, Math.ceil(rows.length / maxTicks));
  const priorityByState = {
    active: "5",
    failed: "0",
    activating: "4",
    reloading: "4",
    inactive: "7",
  };
  for (let index = 0; index < rows.length; index += step) {
    const row = rows[index];
    const stateMatch = row.className.match(/du-state-([a-z]+)/);
    const state = stateMatch ? stateMatch[1] : "inactive";
    const unitLink = row.querySelector("td a");
    const cells = row.querySelectorAll("td");
    const tick = document.createElement("i");
    tick.dataset.rowIndex = String(index);
    tick.dataset.priority = priorityByState[state] || "7";
    // The tooltip template reads ts as the title line: use the
    // unit name there, with the state and description after it.
    tick.dataset.ts = unitLink ? unitLink.textContent.trim() : "";
    tick.dataset.pri = cells[0] ? cells[0].textContent.trim() : state;
    tick.dataset.msg = cells[2]
      ? cells[2].textContent.trim().slice(0, 140)
      : "";
    track.appendChild(tick);
  }
  const label = document.querySelector("#minimap .minimap-label");
  if (label) label.textContent = "units";
}

// Restores the log severity minimap when leaving the dashboard.
function restoreLogsMinimap() {
  const label = document.querySelector("#minimap .minimap-label");
  if (label) label.textContent = "60 min";
  if (window.updateStatsAndMinimap) window.updateStatsAndMinimap();
}
// --- END DASHBOARD SERVICES MINIMAP ---

// Keep the poll URL and dataset in sync after every dashboard
// swap (covers filtering, the time window, and the initial load).
document.body.addEventListener("htmx:afterSwap", function (event) {
  if (event.detail.target && event.detail.target.id === "dashboard-view") {
    syncDashboardStateFromFragment();
    buildServicesMinimap();
  }
  // The AI unit explanation arrives with the raw model output in
  // a hidden div; render it as markdown once swapped in.
  if (event.detail.target && event.detail.target.id === "service-ai-content") {
    const container = document.getElementById("service-ai-content");
    const raw = container && container.querySelector(".ai-answer-raw");
    const out = container && container.querySelector(".ai-answer-rendered");
    if (raw && out) {
      out.innerHTML = window.renderSafeMarkdown(raw.textContent);
    }
  }
});
// --- END DASHBOARD SORTING + FILTERS ---
// --- END DASHBOARD TOGGLE ---

function setHostnameFilterAndTrigger(hostname) {
  const hostnameFilterInput = document.getElementById("hostname-filter");
  if (hostnameFilterInput) {
    hostnameFilterInput.value = hostname;
    // Trigger a custom event that is configured for immediate HTMX requests
    htmx.trigger(hostnameFilterInput, "immediateHostnameFilterUpdate");
  }
  return false; // Prevent default anchor link behavior
}

function setTagFilterAndTrigger(tag) {
  const tagFilterInput = document.getElementById("tag-filter");
  if (tagFilterInput) {
    tagFilterInput.value = tag;
    // Trigger a custom event that is configured for immediate HTMX requests
    htmx.trigger(tagFilterInput, "immediateTagFilterUpdate");
  }
  return false; // Prevent default anchor link behavior
}
// grafito frontend — entry inspector
// Detail/context tabs, hover previews and keyboard handling.

// --- Entry inspector side panel ---
// One docked panel with three tabs (detail / context / AI). The
// server-rendered buttons load their content into a pane and then
// call these helpers to show the panel and switch tabs.
// The entry the panel is currently inspecting, and the one whose
// context has been loaded, so the Context tab can lazy-load.
let currentPanelCursor = null;
let loadedContextCursor = null;
let loadedAICursor = null;

window.showLogPanel = function (tab) {
  const panel = document.getElementById("side-panel");
  if (!panel) return;
  // The service panel (dashboard) only has a Detail view — hide
  // the log-entry tabs while it is showing.
  const serviceMode = !!document.querySelector(
    "#panel-detail-content .service-panel",
  );
  panel.classList.toggle("service-view", serviceMode);
  if (serviceMode && tab !== "detail") tab = "detail";
  panel.classList.add("open");
  document
    .querySelectorAll("#side-panel-tabs .insp-tab")
    .forEach(function (tabButton) {
      const active = tabButton.dataset.tab === tab;
      tabButton.classList.toggle("active", active);
      tabButton.setAttribute("aria-selected", active ? "true" : "false");
    });
  document.querySelectorAll("#side-panel .insp-pane").forEach(function (pane) {
    pane.classList.toggle("active", pane.dataset.pane === tab);
  });
  if (tab === "context" && currentPanelCursor) {
    loadPanelContext(currentPanelCursor);
  }
  if (
    tab === "ai" &&
    currentPanelCursor &&
    loadedAICursor !== currentPanelCursor &&
    !aiDisabledForPanel()
  ) {
    askAIExplanation(currentPanelCursor);
  }
};

// True when the providers list reports AI as unavailable — used to
// avoid firing pointless requests when the AI tab is opened.
function aiDisabledForPanel() {
  const disabledEl = document.getElementById("ai-disabled");
  return !!disabledEl && disabledEl.style.display !== "none";
}

window.loadPanelContext = function (cursor) {
  if (loadedContextCursor === cursor) return; // already loaded
  loadedContextCursor = cursor;
  const pane = document.getElementById("panel-context-content");
  panelSpinner("panel-context-content");
  fetch(`${buildUrl("context")}?${new URLSearchParams({ cursor: cursor })}`)
    .then(function (response) {
      if (!response.ok) {
        throw new Error("HTTP " + response.status);
      }
      return response.text();
    })
    .then(function (html) {
      pane.innerHTML = html;
      // Center the central entry so it is immediately visible.
      const target = pane.querySelector("tr.context-target");
      if (target) {
        target.scrollIntoView({ block: "center" });
      }
    })
    .catch(function (error) {
      console.error("Error fetching log context:", error);
      showError(pane, "Failed to load context: " + error.message);
    });
};

window.closeLogPanel = function () {
  const panel = document.getElementById("side-panel");
  if (panel) panel.classList.remove("open");
};

window.panelSpinner = function (paneId) {
  // Call sites render the id with a leading '#' (hx-on strings);
  // getElementById wants the bare id.
  const pane = document.getElementById(String(paneId).replace(/^#/, ""));
  if (pane) {
    pane.innerHTML = document.getElementById(
      "details-dialog-loading-spinner-template",
    ).innerHTML;
  }
};

window.panelError = function (paneId, status) {
  const pane = document.getElementById(String(paneId).replace(/^#/, ""));
  if (pane) {
    pane.innerHTML =
      '<p class="inline-alert">Failed to load content (HTTP ' +
      status +
      "). Check the server or adjust the filters.</p>";
  }
};

// Remember which entry the panel is inspecting when a row's htmx
// button (details / context) fires.
document.body.addEventListener("htmx:beforeRequest", function (event) {
  const elt = event.detail.elt;
  if (!elt || !elt.closest) return;
  const row = elt.closest("tr.log-row-hover-actions");
  if (row && row.dataset.cursor) {
    currentPanelCursor = row.dataset.cursor;
  }
});

// Clicking a frequency-chart bucket scrolls the stream to that
// moment (first visible entry at or after the bucket start).
document.body.addEventListener("click", function (event) {
  const bar = event.target.closest("g.tl-bar");
  if (!bar || !bar.dataset.start) return;
  const start = Number(bar.dataset.start);
  const interval = Number(
    document.querySelector("#results svg")?.dataset.interval || 3600,
  );
  const rows = document.querySelectorAll(
    "#results table tbody tr.log-row-hover-actions[data-epoch]",
  );
  let target = null;
  rows.forEach(function (row) {
    const epoch = Number(row.dataset.epoch);
    if (target === null && epoch >= start && epoch < start + interval) {
      target = row;
    }
  });
  // Sorting may not be chronological: fall back to the closest entry
  // at or after the bucket start.
  if (!target) {
    rows.forEach(function (row) {
      if (target === null && Number(row.dataset.epoch) >= start) {
        target = row;
      }
    });
  }
  if (!target && rows.length) {
    target = rows[rows.length - 1];
  }
  if (target) {
    target.scrollIntoView({ behavior: "smooth", block: "center" });
    target.classList.remove("row-flash");
    void target.offsetWidth;
    target.classList.add("row-flash");
    setTimeout(function () {
      target.classList.remove("row-flash");
    }, 1300);
  }
});

// Clicking a log entry row opens it in the Detail tab.
document.body.addEventListener("click", function (event) {
  if (event.target.closest("button, a, input, select, summary, dialog")) {
    return;
  }
  const row = event.target.closest("tr.log-row-hover-actions");
  if (!row || !row.dataset.cursor) return;
  currentPanelCursor = row.dataset.cursor;

  const pane = document.getElementById("panel-detail-content");
  panelSpinner("panel-detail-content");
  showLogPanel("detail");
  fetch(
    `${buildUrl("details")}?${new URLSearchParams({
      cursor: row.dataset.cursor,
    })}`,
  )
    .then(function (response) {
      if (!response.ok) {
        throw new Error("HTTP " + response.status);
      }
      return response.text();
    })
    .then(function (html) {
      pane.innerHTML = html;
    })
    .catch(function (error) {
      console.error("Error fetching log details:", error);
      showError(pane, "Failed to load details: " + error.message);
    });
});

document.addEventListener("DOMContentLoaded", function () {
  const closeButton = document.getElementById("side-panel-close");
  if (closeButton) {
    closeButton.addEventListener("click", closeLogPanel);
  }
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      closeLogPanel();
    }
  });
  document
    .querySelectorAll("#side-panel-tabs .insp-tab")
    .forEach(function (tabButton) {
      tabButton.addEventListener("click", function () {
        showLogPanel(tabButton.dataset.tab);
      });
    });
});
// grafito frontend — AI explanations
// Ask/follow-up flows, safe rendering, clipboard export and
// // the provider badge.

// --- AI Explanation Functions ---
let currentAIExplanation = "";
let currentTargetLogEntry = "";
// Conversation state for iterative refinement of the explanation.
let currentAICursor = null;
let currentAIHistory = [];
let currentAIRequest = null;

function appendAIMessage(role, renderedNode) {
  const content = document.getElementById("ai-explanation-dialog-content");
  const message = document.createElement("div");
  message.className = `ai-message ai-message-${role}`;
  if (role === "user") {
    const label = document.createElement("div");
    label.className = "ai-message-label";
    label.textContent = "You asked";
    message.appendChild(label);
    const body = document.createElement("div");
    body.textContent = renderedNode;
    message.appendChild(body);
  } else {
    const label = document.createElement("div");
    label.className = "ai-message-label";
    label.textContent = "AI answer";
    message.appendChild(label);
    message.appendChild(renderedNode);
  }
  content.appendChild(message);
  content.scrollTop = content.scrollHeight;
  return message;
}

function sendAIFollowUp() {
  const input = document.getElementById("ai-followup-input");
  const sendButton = document.getElementById("ai-followup-send");
  const question = (input?.value || "").trim();
  if (!question || currentAIRequest || !currentAICursor) return;

  input.value = "";
  appendAIMessage("user", question);
  currentAIHistory.push({ role: "user", content: question });

  const content = document.getElementById("ai-explanation-dialog-content");
  const pending = document.createElement("div");
  pending.className = "ai-message ai-message-assistant";
  pending.innerHTML = document.getElementById(
    "ai-explanation-loading-template",
  ).innerHTML;
  content.appendChild(pending);
  content.scrollTop = content.scrollHeight;
  sendButton.disabled = true;
  input.disabled = true;
  currentAIRequest = { cursor: currentAICursor };

  const aiRequestBody = { cursor: currentAICursor, history: currentAIHistory };
  if (window.selectedAIProvider) {
    aiRequestBody.provider = window.selectedAIProvider;
  }
  if (window.selectedAIModel) {
    aiRequestBody.model = window.selectedAIModel;
  }
  fetch(buildUrl("ask-ai"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(aiRequestBody),
  })
    .then(async (response) => {
      if (!response.ok) {
        throw new Error(`AI request failed (HTTP ${response.status})`);
      }
      const text = await response.text();
      try {
        return JSON.parse(text);
      } catch (parseError) {
        throw new Error(
          "The AI service returned an unexpected (non-JSON) response.",
        );
      }
    })
    .then((data) => {
      if (data.error) {
        throw new Error(data.error);
      }
      const answer = document.createElement("div");
      answer.innerHTML = window.renderSafeMarkdown(data.content || "");
      if (data.provider || data.model) {
        const note = document.createElement("div");
        note.className = "ai-provider-note";
        note.textContent = `🤖 ${data.provider || "AI"}${
          data.model ? ` (${data.model})` : ""
        }`;
        answer.appendChild(note);
      }
      // Token usage, when the provider reports it: makes the cost of
      // each question visible before the next one.
      if (data.usage && typeof data.usage.total_tokens === "number") {
        const usage = document.createElement("div");
        usage.className = "ai-usage";
        usage.textContent = `${data.usage.input_tokens} in / ${data.usage.output_tokens} out tokens`;
        answer.appendChild(usage);
      }
      appendAIMessage("assistant", answer);
      currentAIHistory.push({ role: "assistant", content: data.content || "" });
    })
    .catch((error) => {
      console.error("Error calling AI:", error);
      pending.remove();
      currentAIHistory.pop(); // drop the failed user turn so retry is clean
      showError(content, `Follow-up failed: ${error.message}`);
    })
    .finally(() => {
      pending.remove();
      sendButton.disabled = false;
      input.disabled = false;
      input.focus();
      currentAIRequest = null;
    });
}

// Helper to display error messages safely (prevents XSS)
function showError(container, message) {
  const p = document.createElement("p");
  p.className = "error";
  p.style.padding = "1em";
  p.textContent = message;
  container.innerHTML = "";
  container.appendChild(p);
}

// Renders the "Log Message:" block in the AI panel's target-entry
// area. `message` is the raw MESSAGE field (truncated here if long)
// or null/empty when there is nothing to show, in which case
// `unavailableText` is displayed instead. Journal messages are
// attacker-controlled (any local user can write one with `logger`),
// so this is built with DOM APIs and textContent — never
// interpolated into innerHTML.
function renderTargetLogMessage(targetEntryDiv, message, unavailableText) {
  targetEntryDiv.textContent = "";
  const label = document.createElement("strong");
  label.textContent = "Log Message:";
  const box = document.createElement("div");
  box.style.marginTop = "0.5rem";
  if (message) {
    box.style.wordBreak = "break-word";
    box.style.lineHeight = "1.4";
    box.textContent =
      message.length > 300 ? message.substring(0, 300) + "..." : message;
  } else {
    box.textContent = unavailableText || "Unable to load log message";
  }
  targetEntryDiv.append(label, document.createElement("br"), box);
}

function askAIExplanation(cursor) {
  const content = document.getElementById("ai-explanation-dialog-content");
  const targetEntryDiv = document.getElementById("target-log-entry");
  const loadingTemplate = document.getElementById(
    "ai-explanation-loading-template",
  );

  // New entry: reset the refinement conversation. This must happen
  // before showLogPanel("ai") — that call auto-triggers the
  // explanation request, and marking the cursor first is what breaks
  // the recursion.
  currentAICursor = cursor;
  currentPanelCursor = cursor;
  loadedAICursor = cursor;
  currentAIHistory = [];

  // Open the AI tab of the inspector and show loading state
  showLogPanel("ai");
  content.innerHTML = loadingTemplate.innerHTML;
  targetEntryDiv.innerHTML = "Loading log entry...";

  // First, get the target log entry details
  fetch(`${buildUrl("details")}?${new URLSearchParams({ cursor: cursor })}`)
    .then(async (response) => {
      if (!response.ok) {
        throw new Error("HTTP " + response.status);
      }
      return response.text();
    })
    .then((html) => {
      // Extract the message from the details page
      const tempDiv = document.createElement("div");
      tempDiv.innerHTML = html;
      // Look for the message content in the details
      const messageElement = tempDiv.querySelector("pre");
      // Journal messages are attacker-controlled (any local user can
      // write one with logger), so the block is built with DOM APIs
      // and textContent — never interpolated into innerHTML.
      let message = "";
      if (messageElement && messageElement.textContent.trim()) {
        try {
          // Parse the JSON and extract just the MESSAGE field
          const logData = JSON.parse(messageElement.textContent.trim());
          message = logData.MESSAGE || messageElement.textContent.trim(); // Fallback to full text if no MESSAGE field
        } catch (e) {
          // If JSON parsing fails, use the full text as fallback
          message = messageElement.textContent.trim();
        }
      }
      currentTargetLogEntry = message;
      renderTargetLogMessage(targetEntryDiv, message ? message : null);
    })
    .catch((error) => {
      console.error("Error fetching log details:", error);
      currentTargetLogEntry = "";
      renderTargetLogMessage(targetEntryDiv, null, "Error loading log message");
    });

  // Call the AI endpoint with selected provider and model
  const aiRequestBody = { cursor: cursor };
  if (window.selectedAIProvider) {
    aiRequestBody.provider = window.selectedAIProvider;
  }
  if (window.selectedAIModel) {
    aiRequestBody.model = window.selectedAIModel;
  }
  fetch(buildUrl("ask-ai"), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(aiRequestBody),
  })
    .then(async (response) => {
      if (!response.ok) {
        throw new Error(`AI request failed (HTTP ${response.status})`);
      }
      // Guard against non-JSON error pages so the message stays useful
      const text = await response.text();
      try {
        return JSON.parse(text);
      } catch (parseError) {
        throw new Error(
          "The AI service returned an unexpected (non-JSON) response.",
        );
      }
    })
    .then((data) => {
      if (data.error) {
        showError(content, `Error: ${data.error}`);
      } else if (data.content) {
        // New normalized response format
        currentAIExplanation = data.content;
        // Convert markdown to HTML through the sanitizer.
        content.innerHTML = window.renderSafeMarkdown(currentAIExplanation);
        // Append provider info safely using textContent (prevents XSS)
        if (data.provider || data.model) {
          const providerDiv = document.createElement("div");
          providerDiv.className = "ai-provider-note";
          const provider = data.provider || "AI";
          const model = data.model || "";
          providerDiv.textContent = `🤖 Powered by ${provider}${
            model ? ` (${model})` : ""
          }`;
          content.appendChild(providerDiv);
        }
      } else {
        showError(content, "Unexpected response format from AI service.");
      }
    })
    .catch((error) => {
      console.error("Error calling AI:", error);
      showError(content, `Failed to get AI explanation: ${error.message}`);
    });
}

// Wire up the follow-up conversation controls
document.addEventListener("DOMContentLoaded", function () {
  const followUpInput = document.getElementById("ai-followup-input");
  const followUpSend = document.getElementById("ai-followup-send");
  if (followUpInput && followUpSend) {
    followUpSend.addEventListener("click", sendAIFollowUp);
    followUpInput.addEventListener("keydown", function (event) {
      if (event.key === "Enter") {
        event.preventDefault();
        sendAIFollowUp();
      }
    });
  }
});

// Copies text to the clipboard and flashes the button's label
// (check icon + "Copied") so the user sees it worked.
function copyTextToClipboard(text, button) {
  copyToClipboard(text, {
    manualFallbackLabel: "Copy the text manually",
    onSuccess: function () {
      flashButtonLabel(
        button,
        '<span class="material-icons" style="vertical-align: middle; font-size: 1rem">check</span> Copied',
      );
    },
  });
}

// Quick copy of a log entry from a table row. Row buttons are
// icon-only, so flash the icon instead of swapping in a label.
function copyLogEntry(text, button) {
  copyToClipboard(text, {
    manualFallbackLabel: "Log entry (copy manually)",
    onSuccess: function () {
      flashButtonIcon(button, "check", "content_copy");
    },
  });
}

function copyEquivalentCommand() {
  copyTextToClipboard(
    document.getElementById("command-dialog-code").textContent,
    document.getElementById("copy-command-btn"),
  );
}

async function loadEquivalentCommand() {
  const code = document.getElementById("command-dialog-code");
  const dialog = document.getElementById("command-dialog");
  code.textContent = "Loading…";
  dialog.showModal();
  try {
    const params = buildFilterURLSearchParams();
    params.set("format", "text");
    const response = await fetch(`${buildUrl("command")}?${params.toString()}`);
    if (!response.ok) {
      throw new Error("HTTP " + response.status);
    }
    let text = await response.text();
    try {
      const parsed = JSON.parse(text);
      if (typeof parsed === "string") {
        text = parsed;
      }
    } catch (e) {
      // plain text response: use as-is
    }
    code.textContent = text.replace(/^"|"$/g, "");
  } catch (error) {
    code.textContent = "Failed to build the command: " + error.message;
  }
}

function copyAIExplanation() {
  if (!currentAIExplanation) {
    alert("No AI explanation to copy.");
    return;
  }
  copyToClipboard(currentAIExplanation, {
    manualFallbackLabel: "AI Explanation (copy manually)",
    onSuccess: function () {
      flashButtonLabel(
        document.getElementById("copy-ai-explanation-btn"),
        '<span class="material-icons" style="vertical-align: middle">check</span> Copied!',
      );
    },
  });
}
// grafito frontend — live SSE tail
// When Live is enabled (and EventSource is available), a server-sent
// events stream (/logs/stream) pushes each new journal entry as a
// ready-made table row; the 10s poller is suspended while the stream
// is open. Falls back to polling when EventSource is unsupported.

let liveSSE = null;

function liveEnabled() {
  const box = document.getElementById("live-view");
  return !!box && box.checked;
}

function liveStreamURL() {
  const params = buildFilterURLSearchParams();
  params.delete("live-view");
  const qs = params.toString();
  return buildUrl("logs/stream") + (qs ? "?" + qs : "");
}

function stopLiveStream() {
  if (liveSSE) {
    liveSSE.close();
    liveSSE = null;
  }
  window.__liveSSEActive = false;
}

function startLiveStream() {
  if (liveSSE || typeof EventSource === "undefined") return;
  stopLiveStream();
  window.__liveSSEActive = true;
  liveSSE = new EventSource(liveStreamURL());
  liveSSE.onerror = function () {
    // A transport-level failure (proxy 502, server restart, auth
    // change) can close the connection for good; without this handler
    // the Live indicator stays lit, polling stays suppressed, and no
    // data ever arrives. Stop for good and let the 10s poller take
    // over — toggling Live off/on retries the stream on demand.
    if (liveSSE && liveSSE.readyState === EventSource.CLOSED) {
      stopLiveStream();
    }
    // readyState === CONNECTING: EventSource is already retrying.
  };
  liveSSE.addEventListener("log", function (event) {
    const tbody = document.querySelector("#results table tbody");
    if (!tbody) return;
    // The payload is a server-rendered <tr>; wrap it to parse.
    const tmp = document.createElement("table");
    tmp.innerHTML = "<tbody>" + event.data + "</tbody>";
    const newRow = tmp.querySelector("tr");
    if (!newRow) return;
    // Skip rows already on screen (dedupe by journal cursor).
    const cursor = newRow.getAttribute("data-cursor");
    if (cursor && tbody.querySelector('[data-cursor="' + cursor + '"]')) {
      return;
    }
    // Newest entries appear at the top (default sort), capped so a
    // chatty journal can't grow the table forever.
    tbody.prepend(newRow);
    while (tbody.rows.length > 1000) {
      tbody.deleteRow(-1);
    }
  });
}

// Entry point called on toggles, swaps and view switches: starts the
// stream when appropriate, stops it otherwise.
function refreshLiveStream() {
  const logsActive = (document.body.dataset.view || "logs") === "logs";
  if (!logsActive || !liveEnabled() || typeof EventSource === "undefined") {
    stopLiveStream();
    return;
  }
  if (!liveSSE) {
    startLiveStream();
  }
}

document.addEventListener("DOMContentLoaded", function () {
  refreshLiveStream();

  const liveViewInput = document.getElementById("live-view");
  if (liveViewInput) {
    liveViewInput.addEventListener("change", function () {
      refreshLiveStream();
    });
  }

  // A full /logs swap (filter/sort/column change) re-renders the
  // table — restart the stream so its filters match what's on screen.
  document.body.addEventListener("htmx:afterSwap", function (event) {
    if (event.detail.target && event.detail.target.id === "results") {
      if (liveEnabled() && typeof EventSource !== "undefined") {
        stopLiveStream();
        startLiveStream();
      }
    }
  });
});
