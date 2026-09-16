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
