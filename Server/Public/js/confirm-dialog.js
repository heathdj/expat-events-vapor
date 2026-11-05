// Styled confirm dialog for hx-confirm (theme: confirm-dialog PR).
//
// htmx fires htmx:confirm before every request. When the element (or an
// ancestor) has hx-confirm, this shows the page's
// <dialog data-confirm-dialog> instead of the browser's own box, and
// sends the request only after "OK". Used by layouts/base.leaf and
// admin/layout.leaf, each with its own styling.
//
// The dialog marks its parts with data-confirm-part="question", "detail"
// (optional), "ok" and "cancel".
//
// Optional attributes, next to hx-confirm:
//   data-confirm-detail  a second line under the question
//   data-confirm-ok      the confirm button's label (default "Yes, continue")
//   data-confirm-cancel  the cancel button's label (default "Go back")
//
// Without <dialog> support it falls back to window.confirm (question and
// detail); if this file doesn't load, htmx shows its own confirm.
//
// Note: htmx forgets which submit button was clicked once focus leaves
// the form, so a confirmed form sends no button name/value or
// formaction. Put what the server needs in hidden inputs instead.
// Added once: htmx re-runs body scripts when it restores a page from its
// history cache.
(function () {
    if (window.expatConfirmReady) { return; }
    window.expatConfirmReady = true;

    document.addEventListener('htmx:confirm', function (evt) {
        var question = evt.detail.question;
        if (!question) { return; }
        var elt = evt.detail.elt;
        var source = elt && elt.closest ? (elt.closest('[hx-confirm], [data-hx-confirm]') || elt) : null;
        var attr = function (name) { return source && source.getAttribute(name); };
        var detail = attr('data-confirm-detail');
        var dialog = document.querySelector('dialog[data-confirm-dialog]');
        var questionEl = dialog && dialog.querySelector('[data-confirm-part=question]');
        var detailEl = dialog && dialog.querySelector('[data-confirm-part=detail]');
        var ok = dialog && dialog.querySelector('[data-confirm-part=ok]');
        var cancel = dialog && dialog.querySelector('[data-confirm-part=cancel]');
        evt.preventDefault();

        // No usable dialog: the browser's own box, with the detail line.
        if (!dialog || typeof dialog.showModal !== 'function' || !questionEl || !ok || !cancel) {
            if (window.confirm(detail ? question + '\n\n' + detail : question)) { evt.detail.issueRequest(true); }
            return;
        }
        // Already asking something (a request triggered by load, polling or
        // script while the dialog is open): drop this one rather than let
        // one "OK" send both.
        if (dialog.open) { return; }

        if (!ok.dataset.defaultLabel) { ok.dataset.defaultLabel = ok.textContent; }
        if (!cancel.dataset.defaultLabel) { cancel.dataset.defaultLabel = cancel.textContent; }
        questionEl.textContent = question;
        if (detailEl) {
            detailEl.textContent = detail || '';
            detailEl.hidden = !detail;
        }
        ok.textContent = attr('data-confirm-ok') || ok.dataset.defaultLabel;
        cancel.textContent = attr('data-confirm-cancel') || cancel.dataset.defaultLabel;

        // Focus goes back to whatever opened the dialog (usually the
        // clicked button) when it's cancelled.
        var opener = document.activeElement;
        var confirmed = false;
        var pressedOnBackdrop = false;
        function onOk() { confirmed = true; dialog.close(); }
        function onCancel() { dialog.close(); }
        // A click counts as "outside" only if it also started outside, so
        // selecting the question's text and releasing outside doesn't close.
        function onPointerDown(e) { pressedOnBackdrop = e.target === dialog; }
        function onBackdrop(e) { if (e.target === dialog && pressedOnBackdrop) { dialog.close(); } }
        function onClose() {
            ok.removeEventListener('click', onOk);
            cancel.removeEventListener('click', onCancel);
            dialog.removeEventListener('pointerdown', onPointerDown);
            dialog.removeEventListener('click', onBackdrop);
            dialog.removeEventListener('close', onClose);
            if (confirmed) {
                evt.detail.issueRequest(true);
            } else if (opener && opener !== document.body && document.contains(opener) && opener.focus) {
                opener.focus();
            }
        }
        ok.addEventListener('click', onOk);
        cancel.addEventListener('click', onCancel);
        dialog.addEventListener('pointerdown', onPointerDown);
        dialog.addEventListener('click', onBackdrop);
        // Escape closes the dialog too (counts as cancel).
        dialog.addEventListener('close', onClose);
        dialog.showModal();
        cancel.focus();
    });
})();
