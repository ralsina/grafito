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
