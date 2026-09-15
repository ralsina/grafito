// grafito frontend — per-view helpers
// View wrappers, process table sort/limit, process panel log
// // jumps, dashboard sorting and the services minimap.

// --- VIEW WRAPPERS ---
// Thin per-view aliases over setViewVisible: they keep the
// call sites (URL restore, panel jumps, sort handlers) readable.

function setDashboardVisible(visible, options) {
  setViewVisible("dashboard", visible, options);
}

function setComposeVisible(visible, options) {
  setViewVisible("compose", visible, options);
}

function setProcessesVisible(visible, options) {
  setViewVisible("processes", visible, options);
}

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
