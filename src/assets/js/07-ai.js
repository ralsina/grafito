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
      if (messageElement && messageElement.textContent.trim()) {
        try {
          // Parse the JSON and extract just the MESSAGE field
          const logData = JSON.parse(messageElement.textContent.trim());
          const message = logData.MESSAGE || messageElement.textContent.trim(); // Fallback to full text if no MESSAGE field

          currentTargetLogEntry = message;
          // Truncate very long messages
          const truncatedMessage =
            currentTargetLogEntry.length > 300
              ? currentTargetLogEntry.substring(0, 300) + "..."
              : currentTargetLogEntry;
          targetEntryDiv.innerHTML = `<strong>Log Message:</strong><br><div style="margin-top: 0.5rem; word-break: break-word; line-height: 1.4;">${truncatedMessage}</div>`;
        } catch (e) {
          // If JSON parsing fails, use the full text as fallback
          currentTargetLogEntry = messageElement.textContent.trim();
          const truncatedMessage =
            currentTargetLogEntry.length > 300
              ? currentTargetLogEntry.substring(0, 300) + "..."
              : currentTargetLogEntry;
          targetEntryDiv.innerHTML = `<strong>Log Message:</strong><br><div style="margin-top: 0.5rem; word-break: break-word; line-height: 1.4;">${truncatedMessage}</div>`;
        }
      } else {
        // No log entry found or empty content
        currentTargetLogEntry = "";
        targetEntryDiv.innerHTML = `<strong>Log Message:</strong><br><div style="margin-top: 0.5rem;">Unable to load log message</div>`;
      }
    })
    .catch((error) => {
      console.error("Error fetching log details:", error);
      currentTargetLogEntry = "";
      targetEntryDiv.innerHTML = `<strong>Log Message:</strong><br><div style="margin-top: 0.5rem;">Error loading log message</div>`;
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

// Shared clipboard helper: copies text and flashes the button (check
// icon plus label) so the user sees it worked. Falls back to an alert
// where clipboard access is unavailable.
function copyTextToClipboard(text, button) {
  if (window.isSecureContext && navigator.clipboard) {
    navigator.clipboard
      .writeText(text)
      .then(() => {
        if (!button) return;
        const original = button.innerHTML;
        button.innerHTML =
          '<span class="material-icons" style="vertical-align: middle; font-size: 1rem">check</span> Copied';
        setTimeout(function () {
          button.innerHTML = original;
        }, 2000);
      })
      .catch((err) => {
        alert("Failed to copy: " + err.message);
      });
  } else {
    alert("Copy the text manually:\n\n" + text);
  }
}

// Quick copy of a log entry from a table row. Row buttons are
// icon-only, so flash the icon instead of swapping in a label.
function copyLogEntry(text, button) {
  if (window.isSecureContext && navigator.clipboard) {
    navigator.clipboard
      .writeText(text)
      .then(() => {
        const icon = button ? button.querySelector(".material-icons") : null;
        if (!icon) return;
        icon.textContent = "check";
        setTimeout(function () {
          icon.textContent = "content_copy";
        }, 1500);
      })
      .catch((err) => {
        alert("Failed to copy: " + err.message);
      });
  } else {
    alert("Log entry (copy manually):\n\n" + text);
  }
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

  if (window.isSecureContext && navigator.clipboard) {
    navigator.clipboard
      .writeText(currentAIExplanation)
      .then(() => {
        // Show brief success feedback
        const copyBtn = document.getElementById("copy-ai-explanation-btn");
        const originalText = copyBtn.innerHTML;
        copyBtn.innerHTML =
          '<span class="material-icons" style="vertical-align: middle">check</span> Copied!';
        setTimeout(() => {
          copyBtn.innerHTML = originalText;
        }, 2000);
      })
      .catch((err) => {
        alert("Failed to copy AI explanation: " + err.message);
      });
  } else {
    // Fallback for non-secure contexts
    alert("AI Explanation (copy manually):\n\n" + currentAIExplanation);
  }
}
