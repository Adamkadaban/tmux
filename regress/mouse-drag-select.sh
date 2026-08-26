#!/bin/sh

# Test mouse-drag-select click replay, drag selection and wheel passthrough.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -LtestA$$ -f/dev/null"
TMUX2="$TEST_TMUX -LtestB$$ -f/dev/null"
TMUX3="$TEST_TMUX -LtestC$$ -f/dev/null"
CAPTURE=$(mktemp)
STANDARD_CAPTURE=$(mktemp)
APP=$(mktemp)

cleanup()
{
	$TMUX kill-server >/dev/null 2>&1
	$TMUX2 kill-server >/dev/null 2>&1
	$TMUX3 kill-server >/dev/null 2>&1
	rm -f "$CAPTURE" "$STANDARD_CAPTURE" "$APP"
}
fail()
{
	echo "$*" >&2
	cleanup
	exit 1
}
send_mouse()
{
	seq="$1"
	$TMUX2 send-keys -t "$OUTER" -l "$seq" 2>/dev/null ||
	    fail "failed to send mouse sequence"
	sleep 0.2
}
end_gesture()
{
	sleep 1
}
capture_hex()
{
	od -An -tx1 "$CAPTURE" 2>/dev/null | tr -d ' \n'
}
sequence_hex()
{
	printf "%s" "$1" | od -An -tx1 | tr -d ' \n'
}
check_capture()
{
	expected="$1"
	message="$2"

	[ "$(capture_hex)" = "$(sequence_hex "$expected")" ] ||
	    fail "$message"
}
restore_drag_binding()
{
	$TMUX bind -n MouseDrag1Pane "$DEFAULT_DRAG_BINDING"
}
check_modified_drag()
{
	key="$1"
	modifier="$2"

	$TMUX bind -n "$key-MouseDrag1Pane" send-keys -M
	: >"$CAPTURE"
	modified_drag=$(printf '\033[<%s;2;2M\033[<%s;6;2M\033[<%s;6;2m' \
	    "$modifier" "$((modifier + 32))" "$modifier")
	send_mouse "$modified_drag"
	check_capture "$modified_drag" "$key drag was changed"
	$TMUX unbind -n "$key-MouseDrag1Pane"
	end_gesture
}

trap cleanup 0 1 15
cleanup

cat >"$APP" <<'EOF'
#!/bin/sh
stty raw -echo
printf 'alpha beta gamma\r\n'
mode=${2:-1002}
printf '\033[?%sh' "$mode"
[ "$mode" = 1000 ] || printf '\033[?1006h'
exec cat >>"$1"
EOF
chmod +x "$APP"
: >"$CAPTURE"

$TMUX new-session -d -s inner -x 80 -y 24 "$APP '$CAPTURE'" || exit 1
$TMUX set -g mouse on
$TMUX set -g mouse-drag-select on
[ "$($TMUX show -gv mouse-drag-select)" = "on" ] ||
	fail "mouse-drag-select is not on"

$TMUX2 new-session -d -x 80 -y 24 "$TMUX attach -t inner" || exit 1
sleep 1
OUTER=$($TMUX2 list-panes -F '#{pane_id}' | head -1)
[ -n "$OUTER" ] || fail "no outer pane"
CLIENT=$($TMUX list-clients -F '#{client_name}' | head -1)
[ -n "$CLIENT" ] || fail "no client attached to inner session"
DEFAULT_DRAG_BINDING=$($TMUX list-keys -T root -F '#{key_command}' \
    MouseDrag1Pane)
[ -n "$DEFAULT_DRAG_BINDING" ] || fail "no default drag binding"
[ "$($TMUX display -pt inner:0.0 '#{mouse_any_flag}')" = "1" ] ||
	fail "test application did not enable mouse tracking"
[ -z "$($TMUX display -pt inner:0.0 '#{mouse_send_drag_flag}')" ] ||
	fail "mouse_send_drag_flag is set outside a drag"

# A plain click is replayed as a press and release.
click=$(printf '\033[<0;5;5M\033[<0;5;5m')
send_mouse "$click"
check_capture "$click" "plain click was not replayed"
end_gesture

# A drag is consumed by tmux, including its deferred press and release.
before=$(capture_hex)
send_mouse "$(printf '\033[<0;1;1M')"
send_mouse "$(printf '\033[<32;5;1M')"
[ "$($TMUX display -pt inner:0.0 '#{pane_in_mode}')" = "1" ] ||
	fail "drag did not enter copy mode"
send_mouse "$(printf '\033[<0;5;1m')"
[ "$(capture_hex)" = "$before" ] ||
	fail "drag leaked mouse events to the application"
[ "$($TMUX show-buffer 2>/dev/null)" = "alph" ] ||
	fail "drag copied unexpected text"
[ "$($TMUX display -pt inner:0.0 '#{pane_in_mode}')" = "0" ] ||
	fail "drag release did not leave copy mode"
end_gesture

# Cancelling copy mode before release consumes the rest of the drag.
: >"$CAPTURE"
send_mouse "$(printf '\033[<0;1;1M')"
send_mouse "$(printf '\033[<32;5;1M')"
$TMUX send-keys -t inner:0.0 -X cancel
send_mouse "$(printf '\033[<0;5;1m')"
check_capture "" "cancelled selection leaked its release"
end_gesture

# Releasing a drag over the status line still completes the selection.
: >"$CAPTURE"
send_mouse "$(printf '\033[<0;1;1M')"
send_mouse "$(printf '\033[<32;5;1M')"
send_mouse "$(printf '\033[<0;5;24m')"
check_capture "" "status-line drag release leaked mouse events"
[ "$($TMUX show-buffer 2>/dev/null)" = "alph" ] ||
	fail "status-line drag release copied unexpected text"
[ "$($TMUX display -pt inner:0.0 '#{pane_in_mode}')" = "0" ] ||
	fail "status-line drag release did not leave copy mode"
end_gesture

# The deferred state was cleared: the next click still reaches the app.
click2=$(printf '\033[<0;7;7M\033[<0;7;7m')
send_mouse "$click2"
check_capture "$click2" "click after drag was not replayed"
end_gesture

# Wheel input remains immediate and is not treated as selection.
wheel=$(printf '\033[<64;9;9M')
send_mouse "$wheel"
check_capture "$click2$wheel" "wheel event did not pass through"
end_gesture

# An intervening wheel event flushes the held press before the wheel.
: >"$CAPTURE"
press=$(printf '\033[<0;8;8M')
click_release=$(printf '\033[<0;8;8m')
send_mouse "$press"
send_mouse "$wheel"
send_mouse "$click_release"
check_capture "$press$wheel$click_release" \
	"wheel event reordered a deferred click"
end_gesture

# An application key also flushes the held press before the key.
: >"$CAPTURE"
send_mouse "$press"
$TMUX2 send-keys -t "$OUTER" -l x
sleep 0.2
send_mouse "$click_release"
check_capture "$press""x$click_release" \
	"key event reordered a deferred click"
end_gesture

# A tmux key binding invalidates the held application click.
: >"$CAPTURE"
send_mouse "$press"
$TMUX2 send-keys -t "$OUTER" C-b C-b
sleep 0.2
send_mouse "$click_release"
bound_key=$(printf '\002')
check_capture "$bound_key$click_release" \
	"bound key reordered a deferred click"
end_gesture

# A custom drag binding that forwards the event gets the held press first.
$TMUX bind -n MouseDrag1Pane send-keys -M
: >"$CAPTURE"
drag=$(printf '\033[<0;2;2M\033[<32;6;2M\033[<0;6;2m')
send_mouse "$drag"
check_capture "$drag" "forwarding drag binding did not receive a complete gesture"
end_gesture

# An unbound drag is forwarded with its pending press.
$TMUX unbind -n MouseDrag1Pane
: >"$CAPTURE"
send_mouse "$drag"
check_capture "$drag" "unbound drag did not receive a complete gesture"
end_gesture

# A binding may consume the drag without leaking a partial gesture.
$TMUX bind -n MouseDrag1Pane display-message
: >"$CAPTURE"
send_mouse "$drag"
check_capture "" "consumed drag leaked mouse events"
end_gesture
restore_drag_binding

# Releasing outside the pane cancels the held press.
: >"$CAPTURE"
send_mouse "$(printf '\033[<0;3;3M\033[<0;3;24m')"
end_gesture
outside_release=$(printf '\033[<0;4;4m')
send_mouse "$outside_release"
check_capture "$outside_release" \
	"release outside pane left a stale deferred press"
end_gesture

# Entering a mode while a press is pending cancels the application click.
: >"$CAPTURE"
send_mouse "$press"
$TMUX copy-mode -t inner:0.0
send_mouse "$click_release"
check_capture "" "pending click was sent into copy mode"
$TMUX send-keys -t inner:0.0 -X cancel
end_gesture

# A click stays cancelled if the mode exits before button release.
: >"$CAPTURE"
send_mouse "$press"
$TMUX copy-mode -t inner:0.0
$TMUX send-keys -t inner:0.0 -X cancel
send_mouse "$click_release"
check_capture "$click_release" \
	"completed mode transition restored a stale click"
end_gesture

# Modified clicks are never deferred.
for modifier in 4 8 16; do
	: >"$CAPTURE"
	modified=$(printf '\033[<%s;5;5M\033[<%s;5;5m' \
	    "$modifier" "$modifier")
	send_mouse "$modified"
	check_capture "$modified" "modified click was changed"
	end_gesture
done

# Toggling the option off during a gesture sends the complete drag.
: >"$CAPTURE"
$TMUX set -g mouse-drag-select on
drag_press=$(printf '\033[<0;2;2M')
drag_move=$(printf '\033[<32;6;2M')
drag_release=$(printf '\033[<0;6;2m')
send_mouse "$drag_press"
$TMUX set -g mouse-drag-select off
send_mouse "$drag_move"
send_mouse "$drag_release"
check_capture "$drag_press$drag_move$drag_release" \
	"option change produced a partial gesture"
end_gesture

# With the option off, the complete drag is sent to the application.
: >"$CAPTURE"
send_mouse "$drag"
check_capture "$drag" "option off did not preserve application mouse handling"
end_gesture

# Modified drags keep their existing application behavior.
$TMUX set -g mouse-drag-select on
check_modified_drag S 4
check_modified_drag M 8
check_modified_drag C 16

# Enabling the option does not change double-click forwarding.
double_click=$(printf '\033[<0;5;5M\033[<0;5;5m\033[<0;5;5M\033[<0;5;5m')
: >"$CAPTURE"
$TMUX set -g mouse-drag-select off
send_mouse "$double_click"
end_gesture
baseline=$(capture_hex)
$TMUX set -g mouse-drag-select on
: >"$CAPTURE"
send_mouse "$double_click"
end_gesture
[ "$(capture_hex)" = "$baseline" ] ||
	fail "option changed double-click forwarding"

# Pending presses are isolated between attached clients.
$TMUX3 new-session -d -x 80 -y 24 "$TMUX attach -t inner" || exit 1
sleep 1
OUTER3=$($TMUX3 list-panes -F '#{pane_id}' | head -1)
[ -n "$OUTER3" ] || fail "no second outer pane"
: >"$CAPTURE"
send_mouse "$press"
other_click=$(printf '\033[<0;10;10M\033[<0;10;10m')
$TMUX3 send-keys -t "$OUTER3" -l "$other_click"
sleep 0.2
send_mouse "$click_release"
check_capture "$other_click$press$click_release" \
	"pending press leaked between clients"
end_gesture

# Switching sessions cancels the pending press for that client.
$TMUX new-session -d -s other -x 80 -y 24 'sleep 30'
: >"$CAPTURE"
send_mouse "$press"
$TMUX switch-client -c "$CLIENT" -t other
send_mouse "$click_release"
$TMUX switch-client -c "$CLIENT" -t inner
send_mouse "$click"
check_capture "$click" "session switch left a stale pending press"
end_gesture

# Switching sessions cancels an active selection drag and its release.
: >"$CAPTURE"
send_mouse "$(printf '\033[<0;1;1M')"
send_mouse "$(printf '\033[<32;5;1M')"
$TMUX switch-client -c "$CLIENT" -t other
send_mouse "$(printf '\033[<0;5;1m')"
$TMUX switch-client -c "$CLIENT" -t inner
check_capture "" "session switch leaked selection drag events"
$TMUX send-keys -t inner:0.0 -X cancel
end_gesture

# Unlinking a shared dragged window cancels its drag state.
$TMUX new-session -d -s holder -x 80 -y 24 'sleep 30'
$TMUX new-window -d -t inner:8 -n fallback 'sleep 30'
$TMUX link-window -s inner:0 -t holder:9
: >"$CAPTURE"
send_mouse "$(printf '\033[<0;1;1M')"
send_mouse "$(printf '\033[<32;5;1M')"
$TMUX unlink-window -t inner:0
send_mouse "$(printf '\033[<0;5;1m')"
check_capture "" "window unlink leaked selection drag events"
$TMUX link-window -s holder:9 -t inner:0
$TMUX select-window -t inner:0
$TMUX send-keys -t inner:0.0 -X cancel
$TMUX move-window -r -t inner:
$TMUX has-session -t inner || fail "renumbering windows killed the server"
$TMUX kill-window -t inner:fallback ||
	fail "failed to remove fallback window"
$TMUX kill-session -t holder
end_gesture

# A read-only transition cannot retain a pending press.
: >"$CAPTURE"
send_mouse "$press"
$TMUX switch-client -c "$CLIENT" -r -t inner
send_mouse "$click_release"
$TMUX switch-client -c "$CLIENT" -r -t inner
$TMUX2 send-keys -t "$OUTER" -l x
sleep 0.2
check_capture x "read-only transition restored a stale click"
end_gesture

# A completed read-only transition also invalidates the pending press.
: >"$CAPTURE"
send_mouse "$press"
$TMUX switch-client -c "$CLIENT" -r -t inner
$TMUX switch-client -c "$CLIENT" -r -t inner
send_mouse "$click_release"
check_capture "$click_release" \
	"completed read-only transition restored a stale click"
end_gesture

# A read-only transition cancels an active selection drag.
: >"$CAPTURE"
send_mouse "$(printf '\033[<0;1;1M')"
send_mouse "$(printf '\033[<32;5;1M')"
$TMUX switch-client -c "$CLIENT" -r -t inner
send_mouse "$(printf '\033[<32;6;1M')"
send_mouse "$(printf '\033[<0;5;1m')"
$TMUX switch-client -c "$CLIENT" -r -t inner
check_capture "" "read-only transition leaked selection drag events"
$TMUX send-keys -t inner:0.0 -X cancel
end_gesture

# Legacy press-only mode also supports tmux drag selection.
$TMUX new-window -d -t inner: -n standard \
	"$APP '$STANDARD_CAPTURE' 1000"
$TMUX select-window -t inner:standard
sleep 1
: >"$STANDARD_CAPTURE"
$TMUX set -g mouse-drag-select off
standard_press=$(printf '\033[<0;5;5M')
standard_release=$(printf '\033[<0;5;5m')
standard_click="$standard_press$standard_release"
send_mouse "$standard_click"
end_gesture
standard_baseline=$(od -An -tx1 "$STANDARD_CAPTURE" | tr -d ' \n')
: >"$STANDARD_CAPTURE"
$TMUX set -g mouse-drag-select on
send_mouse "$standard_click"
[ "$(od -An -tx1 "$STANDARD_CAPTURE" | tr -d ' \n')" = \
    "$standard_baseline" ] ||
	fail "option changed legacy mouse mode click"
end_gesture
: >"$STANDARD_CAPTURE"
send_mouse "$(printf '\033[<0;1;1M')"
send_mouse "$(printf '\033[<32;5;1M')"
[ "$($TMUX display -pt inner:standard '#{pane_in_mode}')" = "1" ] ||
	fail "legacy mouse mode drag did not enter copy mode"
send_mouse "$(printf '\033[<0;5;1m')"
[ ! -s "$STANDARD_CAPTURE" ] ||
	fail "legacy mouse mode drag leaked mouse events"
[ "$($TMUX show-buffer 2>/dev/null)" = "alph" ] ||
	fail "legacy mouse mode drag copied unexpected text"
[ "$($TMUX display -pt inner:standard '#{pane_in_mode}')" = "0" ] ||
	fail "legacy mouse mode drag did not leave copy mode"
end_gesture
$TMUX select-window -t inner:0
sleep 1

# Border drags retain their original drag-end location.
$TMUX split-window -h -d -t inner:0 'sleep 30'
$TMUX copy-mode -t inner:0.0
$TMUX copy-mode -t inner:0.1
send_mouse "$(printf '\033[<0;41;5M')"
send_mouse "$(printf '\033[<32;43;5M')"
send_mouse "$(printf '\033[<0;43;5m')"
[ "$($TMUX display -pt inner:0.0 '#{pane_in_mode}')" = "1" ] ||
	fail "border drag exited copy mode in left pane"
[ "$($TMUX display -pt inner:0.1 '#{pane_in_mode}')" = "1" ] ||
	fail "border drag exited copy mode in right pane"
$TMUX send-keys -t inner:0.0 -X cancel
$TMUX send-keys -t inner:0.1 -X cancel
$TMUX kill-pane -t inner:0.1
end_gesture

# Removing a pane clears any press pending for it.
$TMUX split-window -d -t inner:0 'sleep 30'
: >"$CAPTURE"
send_mouse "$press"
$TMUX kill-pane -t inner:0.0
send_mouse "$click_release"
$TMUX has-session -t inner || fail "pane removal killed the server"

exit 0
