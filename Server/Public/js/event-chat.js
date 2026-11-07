// Event page chat (Event detail PR). The server renders every message the
// same for everyone (live ones arrive over the WebSocket via htmx), so this
// script does the per-reader parts:
//   - shows each time in the reader's own time zone;
//   - marks the reader's own messages (data-user-id against data-me);
//   - Reply: points the next message at that message's thread (replies are
//     one level deep, so replying to a reply joins its thread);
//   - Enter sends, Shift+Enter makes a new line; the box clears after
//     sending;
//   - keeps the list scrolled to the newest message unless the reader has
//     scrolled up;
//   - if the server refuses a message (it sends a #chat-error line back to
//     the sender only), puts the text back in the box.
(function () {
    var chat = document.getElementById('chat');
    if (!chat || chat.dataset.chatReady) { return; }
    chat.dataset.chatReady = 'true';
    var list = document.getElementById('chat-messages');
    // Signed-out visitors get a sign-in box instead of the chat.
    if (!list) { return; }
    var form = chat.querySelector('[data-chat-form]');
    var me = chat.dataset.me || '';

    var sameDay = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
    var otherDay = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });

    function prepare(message) {
        if (!message.classList || !message.classList.contains('chat-message')) { return; }
        var time = message.querySelector('time[data-local-time]');
        if (time && time.getAttribute('datetime')) {
            var when = new Date(time.getAttribute('datetime'));
            if (!isNaN(when)) {
                var today = new Date().toDateString() === when.toDateString();
                time.textContent = (today ? sameDay : otherDay).format(when);
            }
        }
        if (me && message.dataset.userId === me) { message.classList.add('is-me'); }
    }

    function nearBottom() {
        return list.scrollHeight - list.scrollTop - list.clientHeight < 80;
    }

    list.querySelectorAll('.chat-message').forEach(prepare);
    list.scrollTop = list.scrollHeight;

    var stick = true;
    list.addEventListener('scroll', function () { stick = nearBottom(); });
    new MutationObserver(function (changes) {
        changes.forEach(function (change) {
            change.addedNodes.forEach(function (node) {
                if (node.nodeType !== 1) { return; }
                prepare(node);
                var empty = list.querySelector('[data-chat-empty]');
                if (empty) { empty.remove(); }
                var mine = me && node.dataset && node.dataset.userId === me;
                if (stick || mine) { list.scrollTop = list.scrollHeight; }
            });
        });
    }).observe(list, { childList: true });

    if (!form) { return; }
    var text = form.querySelector('textarea[name=text]');
    var parent = form.querySelector('[data-parent-input]');
    var replying = form.querySelector('[data-replying]');
    var replyingName = form.querySelector('[data-replying-name]');

    function clearReply() {
        parent.value = '';
        parent.disabled = true;
        replying.hidden = true;
    }

    list.addEventListener('click', function (event) {
        var button = event.target.closest('[data-reply]');
        if (!button) { return; }
        var message = button.closest('.chat-message');
        parent.value = message.dataset.threadId || message.dataset.messageId;
        parent.disabled = false;
        replyingName.textContent = message.dataset.name || '';
        replying.hidden = false;
        text.focus();
    });
    form.querySelector('[data-cancel-reply]').addEventListener('click', function () {
        clearReply();
        text.focus();
    });
    text.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
            event.preventDefault();
            if (text.value.trim()) { form.requestSubmit(); }
        }
    });
    // htmx's ws-send reads the fields on submit; clear them just after.
    var lastText = '';
    form.addEventListener('submit', function () {
        lastText = text.value;
        var error = document.getElementById('chat-error');
        if (error) { error.hidden = true; error.textContent = ''; }
        setTimeout(function () {
            text.value = '';
            clearReply();
        });
    });
    new MutationObserver(function () {
        var error = document.getElementById('chat-error');
        if (error && !error.hidden && error.textContent.trim() && !text.value) {
            text.value = lastText;
        }
    }).observe(form, { childList: true, subtree: true });
})();
