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
    document.body.addEventListener("htmx:afterRequest", function (event) {
      if (event.detail.error) {
        console.error("HTMX Request Failed. Details:", event.detail); // For debugging
        let errorText = event.detail.error.message || "Failed to send request";
        globalErrorDialogContent.innerHTML = `
                <p role="alert" class="inline-alert">
                  <strong>Details:</strong> ${errorText}
                </p>`;
        if (!globalErrorDialog.open) {
          globalErrorDialog.showModal();
        }
      } else if (event.detail.successful) {
        // If any request succeeds, assume connectivity is restored and close the global error dialog if it's open.
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
      const status = event.detail.xhr ? event.detail.xhr.status : "?";
      console.error(
        "HTMX Request Failed. Status:",
        status,
        "Details:",
        event.detail,
      );
      let errorText = `Server request failed (HTTP ${status})`;
      globalErrorDialogContent.innerHTML = `
              <p role="alert" class="inline-alert">
                <strong>Details:</strong> ${errorText}
              </p>`;
      if (!globalErrorDialog.open) {
        globalErrorDialog.showModal();
      }
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
    const allowedUri = /^(https?:|mailto:|#|\/)/i;
    tpl.content.querySelectorAll("*").forEach(function (el) {
      Array.from(el.attributes).forEach(function (attr) {
        const name = attr.name.toLowerCase();
        const value = (attr.value || "").trim().toLowerCase();
        if (name.startsWith("on")) {
          el.removeAttribute(attr.name);
        } else if (
          (name === "href" || name === "src" || name === "xlink:href") &&
          value &&
          !allowedUri.test(value) &&
          !value.startsWith("data:image/")
        ) {
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

  // --- DEMO MODE DISCLAIMER ---
  // Fake-data (demo site) builds say so in the status bar; real
  // deployments stay quiet. The flag rides on a tiny boot-time fetch
  // so the served HTML is identical for both builds. Failure is
  // purely cosmetic: the banner simply stays hidden.
  fetch(buildUrl("server-info"))
    .then((response) => response.json())
    .then((info) => {
      if (info && info.demo) {
        const banner = document.getElementById("demo-banner");
        if (banner) banner.hidden = false;
      }
    })
    .catch(() => {
      /* no server-info: not fatal, keep the banner hidden */
    });
  // --- END DEMO MODE DISCLAIMER ---

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
  // each view's restore() re-applies its saved state first.
  const requestedView = params.get("view");
  if (requestedView && VIEWS[requestedView]) {
    // Views with state re-apply it first; stateless views (like
    // compose) just open.
    if (!VIEWS[requestedView].restore || VIEWS[requestedView].restore(params)) {
      setViewVisible(requestedView, true);
    }
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
