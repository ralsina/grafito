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
