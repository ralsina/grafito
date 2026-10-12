// CodeMirror wiring for the file editors (compose.yaml, .env,
// homepage.yml). Editor fragments ship a plain <textarea> that htmx
// can serialize; after each swap we upgrade it in place and keep the
// textarea synced on every change so "Review changes" keeps working.

window.initCodeEditors = function (root) {
  if (!root || !root.querySelectorAll) return;
  root
    .querySelectorAll("textarea[data-editor]")
    .forEach(function (textarea) {
      if (textarea.dataset.editorReady) return;
      if (typeof window.CodeMirror === "undefined") return;
      textarea.dataset.editorReady = "1";
      const editor = window.CodeMirror.fromTextArea(textarea, {
        mode: textarea.dataset.editor === "yaml" ? "yaml" : null,
        lineNumbers: true,
        lineWrapping: false,
        indentUnit: 2,
        readOnly: textarea.readOnly,
      });
      // Keep the (hidden) textarea in sync so hx-include serializes
      // the current editor content, not a stale snapshot.
      editor.on("change", function () {
        editor.save();
      });
      editor.setSize(null, "28rem");
    });
};

document.body.addEventListener("htmx:afterSwap", function (event) {
  window.initCodeEditors(event.target);
});
