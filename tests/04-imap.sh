# 04 - Native IMAP: the carrier account logs in through the proxy and gets full
# folder discovery (special-use flags) + IDLE. One probe, several assertions.
ensure_up >/dev/null 2>&1 || true

IMAP_OUT="$(probe imap.py 2>&1)"; IMAP_RC=$?

describe "imap: native experience"

_login()   { assert_ok "$IMAP_RC"; assert_match "$IMAP_OUT" 'login=yes'; note "$IMAP_OUT"; }
it "the carrier account logs in through the proxy" _login

_folders() {
    local n; n=$(printf '%s' "$IMAP_OUT" | grep -oE 'folders=[0-9]+' | cut -d= -f2)
    assert_ge "$n" 1
}
it "folder discovery returns the mailbox folders" _folders

_special() {
    local n; n=$(printf '%s' "$IMAP_OUT" | grep -oE 'special=[0-9]+' | cut -d= -f2)
    assert_ge "$n" 3
}
it "special-use folders (Trash/Sent/Junk/Drafts) are discovered" _special

_idle()    { assert_match "$IMAP_OUT" 'idle=yes'; }
it "IDLE (real-time push) is advertised" _idle
