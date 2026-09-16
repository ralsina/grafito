// grafito frontend — filters runtime
// Filter URL building, the omnibox tokenizer and cross-view
// // jumps (setUnitFilterAndTrigger).

// Helper function to build URLSearchParams from current filters
function buildFilterURLSearchParams() {
  const params = new URLSearchParams();
  SHARED_FILTER_CONFIGS.forEach((config) => {
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

  if (window.isSecureContext && navigator.clipboard) {
    navigator.clipboard
      .writeText(shareUrl)
      .then(() => alert("Link copied to clipboard!"))
      .catch((err) => alert("Failed to copy link: " + err));
  } else {
    // Fallback for non-secure contexts or if clipboard API is not available
    alert("Shareable Link (copy manually):\n\n" + shareUrl);
  }
}

function exportLogsAsText() {
  const params = new URLSearchParams();
  SHARED_FILTER_CONFIGS.forEach((config) => {
    // The 'live-view' parameter is not relevant for a static export
    if (config.param === "live-view") {
      return; // Skip this parameter
    }

    const element = document.getElementById(config.id);
    if (element) {
      if (config.type === "checkbox") {
        // For any other potential checkboxes
        if (element.checked) {
          params.set(config.param, config.trueValue);
        }
      } else if (element.value) {
        // For text inputs and selects
        // Sending empty values (e.g., "" for "Any time") is fine,
        // the backend's optional_query_param handles them as nil.
        params.set(config.param, element.value);
      }
    }
  });

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
