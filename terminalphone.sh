#!/usr/bin/env bash
# TerminalPhone — Encrypted Push-to-Talk Voice over Tor
# A walkie-talkie style voice chat using Tor hidden services
# License: MIT

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
APP_NAME="TerminalPhone"
VERSION="1.0.0"
BASE_DIR="$(dirname "$(readlink -f "$0")")"
DATA_DIR="$BASE_DIR/.terminalphone"
TOR_DIR="$DATA_DIR/tor_data"
TOR_CONF="$DATA_DIR/torrc"
ONION_FILE="$TOR_DIR/hidden_service/hostname"
SECRET_FILE="$DATA_DIR/shared_secret"
CONFIG_FILE="$DATA_DIR/config"
AUDIO_DIR="$DATA_DIR/audio"
PID_DIR="$DATA_DIR/pids"
PTT_FLAG="$DATA_DIR/run/ptt_$$"
CONNECTED_FLAG="$DATA_DIR/run/connected_$$"
RECV_PIPE="$DATA_DIR/run/recv_$$"
SEND_PIPE="$DATA_DIR/run/send_$$"

# Defaults
LISTEN_PORT=7777
TOR_SOCKS_PORT=9050
OPUS_BITRATE=16       # kbps — good balance of quality and bandwidth for Tor
OPUS_FRAMESIZE=60     # ms
SAMPLE_RATE=8000      # Hz
PTT_KEY=" "           # spacebar
CHUNK_DURATION=1      # seconds per audio chunk

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
BLINK='\033[5m'
NC='\033[0m' # No Color
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_BLUE='\033[44m'
TOR_PURPLE='\033[38;2;125;70;152m'

# Platform detection
IS_TERMUX=0
if [ -n "${TERMUX_VERSION:-}" ] || { [ -n "${PREFIX:-}" ] && [[ "${PREFIX:-}" == *"com.termux"* ]]; }; then
    IS_TERMUX=1
fi

# State
TOR_PID=""
LISTENER_PID=""
CALL_ACTIVE=0
ORIGINAL_STTY=""

#=============================================================================
# HELPERS
#=============================================================================

cleanup() {
    # Restore terminal
    if [ -n "$ORIGINAL_STTY" ]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || true
    fi
    stty sane 2>/dev/null || true

    # Kill background processes
    kill_bg_processes

    # Remove temp files
    rm -f "$PTT_FLAG" "$CONNECTED_FLAG" "$RECV_PIPE" "$SEND_PIPE"
    rm -rf "$AUDIO_DIR" 2>/dev/null || true

    echo -e "\n${GREEN}${APP_NAME} shut down cleanly.${NC}"
}

kill_bg_processes() {
    # Kill any child processes
    local pids
    pids=$(jobs -p 2>/dev/null) || true
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
        wait $pids 2>/dev/null || true
    fi

    # Kill stored PIDs
    if [ -d "$PID_DIR" ]; then
        for pidfile in "$PID_DIR"/*.pid; do
            [ -f "$pidfile" ] || continue
            local pid
            pid=$(cat "$pidfile" 2>/dev/null) || continue
            kill "$pid" 2>/dev/null || true
        done
        rm -f "$PID_DIR"/*.pid 2>/dev/null || true
    fi

    # Kill our Tor instance if running
    if [ -n "$TOR_PID" ] && kill -0 "$TOR_PID" 2>/dev/null; then
        kill "$TOR_PID" 2>/dev/null || true
    fi
}

save_pid() {
    local name="$1" pid="$2"
    mkdir -p "$PID_DIR"
    echo "$pid" > "$PID_DIR/${name}.pid"
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_ok() {
    echo -e "${GREEN}[  OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_err() {
    echo -e "${RED}[FAIL]${NC} $1"
}

uid() {
    echo "$(date +%s%N 2>/dev/null || date +%s)_${RANDOM}"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    if [ -f "$SECRET_FILE" ]; then
        SHARED_SECRET=$(cat "$SECRET_FILE")
    else
        SHARED_SECRET=""
    fi
}

save_config() {
    mkdir -p "$DATA_DIR"
    cat > "$CONFIG_FILE" << EOF
LISTEN_PORT=$LISTEN_PORT
TOR_SOCKS_PORT=$TOR_SOCKS_PORT
OPUS_BITRATE=$OPUS_BITRATE
PTT_KEY="$PTT_KEY"
EOF
}

#=============================================================================
# DEPENDENCY INSTALLER
#=============================================================================

check_dep() {
    command -v "$1" &>/dev/null
}

install_deps() {
    echo -e "\n${BOLD}${CYAN}═══ Dependency Installer ═══${NC}\n"

    local deps_needed=()
    local all_deps
    local pkg_names_apt="tor opus-tools sox socat openssl alsa-utils"
    local pkg_names_dnf="tor opus-tools sox socat openssl alsa-utils"
    local pkg_names_pacman="tor opus-tools sox socat openssl alsa-utils"
    local pkg_names_pkg="tor opus-tools sox socat openssl-tool ffmpeg termux-api"

    # Shared deps + platform-specific
    if [ $IS_TERMUX -eq 1 ]; then
        all_deps=(tor opusenc opusdec sox socat openssl ffmpeg termux-microphone-record)
    else
        all_deps=(tor opusenc opusdec sox socat openssl arecord aplay)
    fi

    # Check which deps are missing
    for dep in "${all_deps[@]}"; do
        if check_dep "$dep"; then
            log_ok "$dep found"
        else
            deps_needed+=("$dep")
            log_warn "$dep NOT found"
        fi
    done

    if [ ${#deps_needed[@]} -eq 0 ]; then
        echo -e "\n${GREEN}All dependencies are installed!${NC}"
        return 0
    fi

    echo -e "\n${YELLOW}Missing dependencies: ${deps_needed[*]}${NC}"
    echo -e "Attempting to install...\n"

    # Use sudo only if available and not on Termux
    local SUDO="sudo"
    if [ $IS_TERMUX -eq 1 ]; then
        SUDO=""
        log_info "Termux detected — installing without sudo"
    elif ! check_dep sudo; then
        SUDO=""
    fi

    # Detect package manager and install
    if [ $IS_TERMUX -eq 1 ]; then
        log_info "Detected Termux"
        log_info "Upgrading existing packages first..."
        pkg upgrade -y
        pkg install -y $pkg_names_pkg
        echo -e "\n${YELLOW}${BOLD}NOTE:${NC} You must also install the ${BOLD}Termux:API${NC} app from F-Droid"
        echo -e "      for microphone access.\n"
    elif check_dep apt-get; then
        log_info "Detected apt package manager"
        $SUDO apt-get update -qq
        $SUDO apt-get install -y $pkg_names_apt
    elif check_dep dnf; then
        log_info "Detected dnf package manager"
        $SUDO dnf install -y $pkg_names_dnf
    elif check_dep pacman; then
        log_info "Detected pacman package manager"
        $SUDO pacman -S --noconfirm $pkg_names_pacman
    else
        log_err "No supported package manager found!"
        log_err "Please install manually: tor, opus-tools, sox, socat, openssl, alsa-utils"
        return 1
    fi

    # Verify
    echo -e "\n${BOLD}Verifying installation...${NC}"
    local failed=0
    for dep in "${all_deps[@]}"; do
        if check_dep "$dep"; then
            log_ok "$dep"
        else
            log_err "$dep still missing!"
            failed=1
        fi
    done

    if [ $failed -eq 0 ]; then
        echo -e "\n${GREEN}${BOLD}All dependencies installed successfully!${NC}"
    else
        echo -e "\n${RED}Some dependencies could not be installed.${NC}"
        return 1
    fi
}

#=============================================================================
# TOR HIDDEN SERVICE
#=============================================================================

setup_tor() {
    mkdir -p "$TOR_DIR/hidden_service"
    chmod 700 "$TOR_DIR/hidden_service"

    cat > "$TOR_CONF" << EOF
SocksPort $TOR_SOCKS_PORT
DataDirectory $TOR_DIR/data
HiddenServiceDir $TOR_DIR/hidden_service
HiddenServicePort $LISTEN_PORT 127.0.0.1:$LISTEN_PORT
Log notice file $TOR_DIR/tor.log
EOF
    chmod 600 "$TOR_CONF"
}

start_tor() {
    if [ -n "$TOR_PID" ] && kill -0 "$TOR_PID" 2>/dev/null; then
        log_info "Tor is already running (PID $TOR_PID)"
        return 0
    fi

    setup_tor

    # Clear old log so we only see fresh output
    local tor_log="$TOR_DIR/tor.log"
    > "$tor_log"

    log_info "Starting Tor..."
    tor -f "$TOR_CONF" &>/dev/null &
    TOR_PID=$!
    save_pid "tor" "$TOR_PID"

    # Monitor bootstrap progress from the log
    local waited=0
    local timeout=120
    local last_pct=""

    while [ $waited -lt $timeout ]; do
        # Check if Tor is still running
        if ! kill -0 "$TOR_PID" 2>/dev/null; then
            echo ""
            log_err "Tor process died! Check $tor_log"
            [ -f "$tor_log" ] && tail -5 "$tor_log" 2>/dev/null
            return 1
        fi

        # Parse latest bootstrap line from log
        local bootstrap_line=""
        bootstrap_line=$(grep -o "Bootstrapped [0-9]*%.*" "$tor_log" 2>/dev/null | tail -1 || true)

        if [ -n "$bootstrap_line" ]; then
            local pct=""
            pct=$(echo "$bootstrap_line" | grep -o '[0-9]*%' || true)
            if [ -n "$pct" ] && [ "$pct" != "$last_pct" ]; then
                echo -ne "\r  ${DIM}${bootstrap_line}${NC}                    "
                last_pct="$pct"
            fi

            # Check for 100%
            if [[ "$bootstrap_line" == *"100%"* ]]; then
                echo ""
                break
            fi
        else
            # No bootstrap line yet, show waiting indicator
            echo -ne "\r  ${DIM}Waiting for Tor to start...${NC} "
        fi

        sleep 1
        waited=$((waited + 1))
    done

    if [ $waited -ge $timeout ]; then
        echo ""
        log_err "Timed out waiting for Tor to bootstrap ($timeout seconds)"
        return 1
    fi

    # Wait for onion address file (should appear quickly after 100%)
    local addr_wait=0
    while [ ! -f "$ONION_FILE" ] && [ $addr_wait -lt 15 ]; do
        sleep 1
        addr_wait=$((addr_wait + 1))
    done

    if [ -f "$ONION_FILE" ]; then
        local onion
        onion=$(cat "$ONION_FILE")
        log_ok "Tor hidden service active"
        echo -e "  ${BOLD}${GREEN}Your address: ${WHITE}${onion}${NC}"
        return 0
    else
        log_err "Tor bootstrapped but hidden service address not found"
        return 1
    fi
}

stop_tor() {
    if [ -n "$TOR_PID" ] && kill -0 "$TOR_PID" 2>/dev/null; then
        kill "$TOR_PID" 2>/dev/null || true
        wait "$TOR_PID" 2>/dev/null || true
        TOR_PID=""
        log_ok "Tor stopped"
    fi
}

get_onion() {
    if [ -f "$ONION_FILE" ]; then
        cat "$ONION_FILE"
    else
        echo ""
    fi
}

rotate_onion() {
    echo -e "\n${BOLD}${CYAN}═══ Rotate Onion Address ═══${NC}\n"
    local old_onion
    old_onion=$(get_onion)
    if [ -n "$old_onion" ]; then
        echo -e "  ${DIM}Current: ${old_onion}${NC}"
    fi
    echo -e "  ${YELLOW}This will generate a new .onion address.${NC}"
    echo -e "  ${YELLOW}The old address will stop working.${NC}\n"
    echo -ne "  ${BOLD}Continue? [y/N]: ${NC}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Cancelled"
        return
    fi
    stop_tor
    rm -rf "$TOR_DIR/hidden_service"
    log_info "Old hidden service keys deleted"
    start_tor
}

#=============================================================================
# ENCRYPTION
#=============================================================================

set_shared_secret() {
    echo -e "\n${BOLD}${CYAN}═══ Set Shared Secret ═══${NC}\n"
    echo -e "${DIM}Both parties must use the same secret for the call to work.${NC}"
    echo -e "${DIM}Share this secret securely (in person, via encrypted message, etc.)${NC}\n"

    if [ -n "$SHARED_SECRET" ]; then
        echo -e "Current secret: ${DIM}(set)${NC}"
    else
        echo -e "Current secret: ${DIM}(none)${NC}"
    fi

    echo -ne "\n${BOLD}Enter shared secret: ${NC}"
    read -r new_secret

    if [ -z "$new_secret" ]; then
        log_warn "Secret not changed"
        return
    fi

    SHARED_SECRET="$new_secret"
    mkdir -p "$DATA_DIR"
    echo "$SHARED_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    log_ok "Shared secret saved"
}

# Encrypt stdin to stdout
encrypt_stream() {
    openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -pass "pass:${SHARED_SECRET}" -nosalt 2>/dev/null
}

# Decrypt stdin to stdout
decrypt_stream() {
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass "pass:${SHARED_SECRET}" -nosalt 2>/dev/null
}

# Encrypt a file
encrypt_file() {
    local infile="$1" outfile="$2"
    openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -pass "pass:${SHARED_SECRET}" \
        -in "$infile" -out "$outfile" 2>/dev/null
}

# Decrypt a file
decrypt_file() {
    local infile="$1" outfile="$2"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass "pass:${SHARED_SECRET}" \
        -in "$infile" -out "$outfile" 2>/dev/null
}

#=============================================================================
# AUDIO PIPELINE
#=============================================================================

# Record a timed chunk of raw audio (used by audio test)
audio_record() {
    local outfile="$1"
    local duration="${2:-$CHUNK_DURATION}"

    if [ $IS_TERMUX -eq 1 ]; then
        local tmp_rec="$AUDIO_DIR/tmrec_$(uid).m4a"
        rm -f "$tmp_rec"
        termux-microphone-record -l "$((duration + 1))" -f "$tmp_rec" &>/dev/null
        sleep "$duration"
        termux-microphone-record -q &>/dev/null || true
        sleep 0.5
        if [ -s "$tmp_rec" ]; then
            ffmpeg -y -i "$tmp_rec" -f s16le -ar "$SAMPLE_RATE" -ac 1 \
                "$outfile" &>/dev/null || log_warn "ffmpeg conversion failed"
        fi
        rm -f "$tmp_rec"
    else
        arecord -f S16_LE -r "$SAMPLE_RATE" -c 1 -t raw -d "$duration" \
            -q "$outfile" 2>/dev/null
    fi
}

# Start continuous recording in background (returns immediately)
# Sets REC_PID and REC_FILE globals
start_recording() {
    local _id=$(uid)

    if [ $IS_TERMUX -eq 1 ]; then
        REC_FILE="$AUDIO_DIR/msg_${_id}.m4a"
        rm -f "$REC_FILE"
        termux-microphone-record -l 120 -f "$REC_FILE" &>/dev/null &
        REC_PID=$!
    else
        REC_FILE="$AUDIO_DIR/msg_${_id}.raw"
        arecord -f S16_LE -r "$SAMPLE_RATE" -c 1 -t raw -q "$REC_FILE" 2>/dev/null &
        REC_PID=$!
    fi
}

# Stop recording and send the message
# Encodes, encrypts, base64-encodes, and writes to fd 4
stop_and_send() {
    local _id=$(uid)
    local raw_file="$AUDIO_DIR/tx_${_id}.raw"
    local opus_file="$AUDIO_DIR/tx_${_id}.opus"
    local enc_file="$AUDIO_DIR/tx_enc_${_id}.opus"

    # Stop the recording
    if [ $IS_TERMUX -eq 1 ]; then
        termux-microphone-record -q &>/dev/null || true
        kill "$REC_PID" 2>/dev/null || true
        wait "$REC_PID" 2>/dev/null || true
        sleep 0.3  # let file flush
        # Convert m4a → raw PCM
        if [ -s "$REC_FILE" ]; then
            ffmpeg -y -i "$REC_FILE" -f s16le -ar "$SAMPLE_RATE" -ac 1 \
                "$raw_file" &>/dev/null || true
        fi
        rm -f "$REC_FILE"
    else
        kill "$REC_PID" 2>/dev/null || true
        wait "$REC_PID" 2>/dev/null || true
        raw_file="$REC_FILE"  # already in raw format
    fi

    REC_PID=""
    REC_FILE=""

    # Encode → encrypt → send
    if [ -s "$raw_file" ]; then
        echo -ne "\r  ${DIM}Sending...${NC}                                     " >&2
        opusenc --raw --raw-rate "$SAMPLE_RATE" --raw-chan 1 \
            --bitrate "$OPUS_BITRATE" --framesize "$OPUS_FRAMESIZE" \
            --speech --quiet \
            "$raw_file" "$opus_file" 2>/dev/null

        if [ -s "$opus_file" ]; then
            encrypt_file "$opus_file" "$enc_file" 2>/dev/null
            if [ -s "$enc_file" ]; then
                local b64
                b64=$(base64 -w 0 "$enc_file" 2>/dev/null)
                echo "AUDIO:${b64}" >&4 2>/dev/null || true
            fi
        fi
    fi
    rm -f "$raw_file" "$opus_file" "$enc_file" 2>/dev/null
}

# Play audio (platform-aware)
audio_play() {
    local infile="$1"
    local rate="${2:-48000}"

    if [ $IS_TERMUX -eq 1 ]; then
        # Termux: use Android's native media player
        termux-media-player play "$infile" &>/dev/null || true
        # Wait for playback to finish
        while termux-media-player info 2>/dev/null | grep -q "playing"; do
            sleep 0.5
        done
    else
        # Linux: use ALSA aplay
        aplay -f S16_LE -r "$rate" -c 1 -q "$infile" 2>/dev/null
    fi
}

# Record a chunk of audio, encode to opus, return the file path
record_chunk() {
    local _id=$(uid)
    local raw_file="$AUDIO_DIR/rec_${_id}.raw"
    local opus_file="$AUDIO_DIR/rec_${_id}.opus"

    # Record raw audio
    audio_record "$raw_file" "$CHUNK_DURATION"

    # Encode to opus
    if [ -s "$raw_file" ]; then
        opusenc --raw --raw-rate "$SAMPLE_RATE" --raw-chan 1 \
            --bitrate "$OPUS_BITRATE" --framesize "$OPUS_FRAMESIZE" \
            --speech --quiet \
            "$raw_file" "$opus_file" 2>/dev/null
    fi

    rm -f "$raw_file"
    echo "$opus_file"
}

# Play an opus file
play_chunk() {
    local opus_file="$1"

    if [ $IS_TERMUX -eq 1 ]; then
        # Termux: decode to wav, play via Android media player
        local wav_file="$AUDIO_DIR/play_$(uid).wav"
        opusdec --quiet "$opus_file" "$wav_file" 2>/dev/null || true
        if [ -s "$wav_file" ]; then
            audio_play "$wav_file"
        fi
        rm -f "$wav_file"
    else
        # Linux: pipe decode directly to aplay
        opusdec --quiet --rate 48000 "$opus_file" - 2>/dev/null | \
            aplay -f S16_LE -r 48000 -c 1 -q 2>/dev/null || true
    fi
}

#=============================================================================
# PROTOCOL — FRAMED MESSAGES
#=============================================================================
# Message format: [1 byte type][4 bytes length (big-endian)][payload]
# Types: 0x01 = voice data, 0x02 = PTT start, 0x03 = PTT stop, 0x04 = ping, 0x05 = text

PROTO_VOICE=1
PROTO_PTT_START=2
PROTO_PTT_STOP=3
PROTO_PING=4
PROTO_TEXT=5

# Send a framed message over the connection fd
send_message() {
    local msg_type="$1"
    local payload_file="$2"  # file containing payload, or empty
    local fd="$3"

    local payload_len=0
    if [ -n "$payload_file" ] && [ -f "$payload_file" ]; then
        payload_len=$(stat -c%s "$payload_file" 2>/dev/null || echo 0)
    fi

    # Write header: type (1 byte) + length (4 bytes big-endian)
    printf "\\x$(printf '%02x' "$msg_type")" >&"$fd"
    printf "\\x$(printf '%02x' $(( (payload_len >> 24) & 0xFF )))" >&"$fd"
    printf "\\x$(printf '%02x' $(( (payload_len >> 16) & 0xFF )))" >&"$fd"
    printf "\\x$(printf '%02x' $(( (payload_len >> 8) & 0xFF )))" >&"$fd"
    printf "\\x$(printf '%02x' $(( payload_len & 0xFF )))" >&"$fd"

    # Write payload
    if [ "$payload_len" -gt 0 ]; then
        cat "$payload_file" >&"$fd"
    fi
}

#=============================================================================
# CONNECTION HANDLER
#=============================================================================

# Background process: handle receiving data from remote
receive_loop() {
    local conn_fd="$1"
    mkdir -p "$AUDIO_DIR"

    while [ -f "$CONNECTED_FLAG" ]; do
        # Read message header (5 bytes: 1 type + 4 length)
        local header
        header=$(dd bs=1 count=5 <&"$conn_fd" 2>/dev/null | xxd -p)

        if [ -z "$header" ] || [ ${#header} -lt 10 ]; then
            sleep 0.1
            continue
        fi

        local msg_type=$((16#${header:0:2}))
        local payload_len=$((16#${header:2:8}))

        case $msg_type in
            $PROTO_VOICE)
                if [ "$payload_len" -gt 0 ]; then
                    local _rid=$(uid)
                    local enc_file="$AUDIO_DIR/recv_enc_${_rid}.opus"
                    local dec_file="$AUDIO_DIR/recv_${_rid}.opus"
                    dd bs=1 count="$payload_len" <&"$conn_fd" > "$enc_file" 2>/dev/null
                    if decrypt_file "$enc_file" "$dec_file"; then
                        play_chunk "$dec_file"
                    fi
                    rm -f "$enc_file" "$dec_file"
                fi
                ;;
            $PROTO_PTT_START)
                echo -e "\r${BG_GREEN}${WHITE} ▶ REMOTE SPEAKING ${NC}  " >&2
                ;;
            $PROTO_PTT_STOP)
                echo -e "\r${DIM} ■ Remote idle      ${NC}  " >&2
                ;;
            $PROTO_PING)
                # Respond with ping
                ;;
            *)
                ;;
        esac
    done
}

# Background process: handle sending based on PTT state
transmit_loop() {
    local conn_fd="$1"
    local was_pressed=0
    mkdir -p "$AUDIO_DIR"

    while [ -f "$CONNECTED_FLAG" ]; do
        if [ -f "$PTT_FLAG" ]; then
            if [ $was_pressed -eq 0 ]; then
                # PTT just pressed — notify remote
                was_pressed=1
                local empty_file="$AUDIO_DIR/empty_$(uid)"
                touch "$empty_file"
                send_message $PROTO_PTT_START "$empty_file" "$conn_fd" 2>/dev/null || true
                rm -f "$empty_file"
            fi

            # Record a chunk, encrypt, and send
            local opus_file
            opus_file=$(record_chunk)
            if [ -f "$opus_file" ]; then
                local enc_file="$AUDIO_DIR/send_enc_$(uid).opus"
                if encrypt_file "$opus_file" "$enc_file"; then
                    send_message $PROTO_VOICE "$enc_file" "$conn_fd" 2>/dev/null || true
                fi
                rm -f "$opus_file" "$enc_file"
            fi
        else
            if [ $was_pressed -eq 1 ]; then
                # PTT just released — notify remote
                was_pressed=0
                local empty_file="$AUDIO_DIR/empty_$(uid)"
                touch "$empty_file"
                send_message $PROTO_PTT_STOP "$empty_file" "$conn_fd" 2>/dev/null || true
                rm -f "$empty_file"
            fi
            sleep 0.1
        fi
    done
}

# Start listening for incoming calls
listen_for_call() {
    if [ -z "$SHARED_SECRET" ]; then
        log_err "No shared secret set! Use option 4 first."
        return 1
    fi

    start_tor || return 1

    local onion
    onion=$(get_onion)
    echo -e "\n${BOLD}${CYAN}═══ Listening for Calls ═══${NC}\n"
    echo -e "  ${GREEN}Your address:${NC} ${BOLD}${WHITE}$onion${NC}"
    echo -e "  ${GREEN}Listening on:${NC} port $LISTEN_PORT"
    echo -e "\n  ${DIM}Share your .onion address with the caller.${NC}"
    echo -e "  ${DIM}Press Ctrl+C to stop listening.${NC}\n"

    mkdir -p "$AUDIO_DIR"

    # Use socat to accept a TCP connection, then handle it
    log_info "Waiting for incoming connection..."

    # Create named pipes for bidirectional communication
    rm -f "$RECV_PIPE" "$SEND_PIPE"
    mkfifo "$RECV_PIPE" "$SEND_PIPE"

    # Flag file that socat will create when a connection arrives
    local incoming_flag="$DATA_DIR/run/incoming_$$"
    rm -f "$incoming_flag"

    # Start socat in background — it touches the flag when someone connects
    socat "TCP-LISTEN:$LISTEN_PORT,reuseaddr" \
        "SYSTEM:touch $incoming_flag; cat $SEND_PIPE & cat > $RECV_PIPE" &
    local socat_pid=$!
    save_pid "socat" "$socat_pid"

    # Wait for an incoming connection (poll for the flag file)
    while [ ! -f "$incoming_flag" ]; do
        if ! kill -0 "$socat_pid" 2>/dev/null; then
            log_err "Listener stopped unexpectedly"
            rm -f "$RECV_PIPE" "$SEND_PIPE" "$incoming_flag"
            return 1
        fi
        sleep 0.5
    done

    touch "$CONNECTED_FLAG"
    log_ok "Call connected!"
    in_call_session "$RECV_PIPE" "$SEND_PIPE" ""

    # Cleanup after call ends
    kill "$socat_pid" 2>/dev/null || true
    rm -f "$CONNECTED_FLAG" "$RECV_PIPE" "$SEND_PIPE" "$incoming_flag"
}

# Call a remote .onion address
call_remote() {
    if [ -z "$SHARED_SECRET" ]; then
        log_err "No shared secret set! Use option 4 first."
        return 1
    fi

    echo -e "\n${BOLD}${CYAN}═══ Make a Call ═══${NC}\n"
    echo -ne "  ${BOLD}Enter .onion address: ${NC}"
    read -r remote_onion

    if [ -z "$remote_onion" ]; then
        log_warn "No address entered"
        return 1
    fi

    # Append .onion if not present
    if [[ "$remote_onion" != *.onion ]]; then
        remote_onion="${remote_onion}.onion"
    fi

    start_tor || return 1

    echo -e "\n  ${DIM}Connecting to ${remote_onion}:${LISTEN_PORT} via Tor...${NC}"

    mkdir -p "$AUDIO_DIR"
    touch "$CONNECTED_FLAG"

    # Create named pipes
    rm -f "$RECV_PIPE" "$SEND_PIPE"
    mkfifo "$RECV_PIPE" "$SEND_PIPE"

    # Connect via Tor SOCKS proxy using socat
    socat "SOCKS4A:127.0.0.1:${remote_onion}:${LISTEN_PORT},socksport=${TOR_SOCKS_PORT}" \
          "SYSTEM:cat $SEND_PIPE & cat > $RECV_PIPE" &
    local socat_pid=$!
    save_pid "socat_call" "$socat_pid"

    # Give socat a moment to connect
    sleep 2

    if kill -0 "$socat_pid" 2>/dev/null; then
        log_ok "Connected to ${remote_onion}!"
        in_call_session "$RECV_PIPE" "$SEND_PIPE" "$remote_onion"
    else
        log_err "Failed to connect. Check the address and ensure Tor is running."
    fi

    rm -f "$CONNECTED_FLAG" "$RECV_PIPE" "$SEND_PIPE"
}

#=============================================================================
# IN-CALL SESSION — PTT VOICE LOOP
#=============================================================================

in_call_session() {
    local recv_pipe="$1"
    local send_pipe="$2"
    local known_remote="${3:-}"

    CALL_ACTIVE=1
    rm -f "$PTT_FLAG"
    mkdir -p "$AUDIO_DIR"

    # Open persistent file descriptors for the pipes
    exec 3< "$recv_pipe"  # fd 3 = read from remote
    exec 4> "$send_pipe"  # fd 4 = write to remote

    # Send our onion address for caller ID
    local my_onion
    my_onion=$(get_onion)
    if [ -n "$my_onion" ]; then
        echo "ID:${my_onion}" >&4 2>/dev/null || true
    fi

    # Remote address (populated by receive loop)
    local remote_id_file="$DATA_DIR/run/remote_id_$$"
    rm -f "$remote_id_file"

    # If we don't know the remote address yet (listener), wait briefly for handshake
    local remote_display="$known_remote"
    if [ -z "$remote_display" ]; then
        # Read the first line — should be the ID handshake
        local first_line=""
        if read -r -t 3 first_line <&3 2>/dev/null; then
            if [[ "$first_line" == ID:* ]]; then
                remote_display="${first_line#ID:}"
                echo "$remote_display" > "$remote_id_file"
            fi
        fi
    fi

    # Show header with remote address
    if [ -n "$remote_display" ]; then
        echo -e "\n${BOLD}${BG_GREEN}${WHITE} CALL CONNECTED ${NC} ${CYAN}${remote_display}${NC}\n"
    else
        echo -e "\n${BOLD}${BG_GREEN}${WHITE} CALL CONNECTED ${NC}\n"
    fi
    echo -e "  ${BOLD}Controls:${NC}"
    echo -e "  ${GREEN}[SPACE]${NC} -- Push-to-Talk"
    echo -e "  ${CYAN}[T]${NC}     -- Send text message"
    echo -e "  ${RED}[Q]${NC}     -- Hang up"
    echo -e ""

    # Start receive handler in background
    # Protocol: ID:<onion>, PTT_START, PTT_STOP, PING,
    #           or "AUDIO:<base64_encoded_encrypted_opus>"
    (
        while [ -f "$CONNECTED_FLAG" ]; do
            local line=""
            if read -r line <&3 2>/dev/null; then
                case "$line" in
                    PTT_START)
                        echo -ne "\r  ${BG_GREEN}${WHITE}${BOLD} REMOTE TALKING ${NC}   "
                        ;;
                    PTT_STOP)
                        echo -ne "\r  ${DIM} Remote idle       ${NC}   "
                        ;;
                    PING)
                        echo -ne "\r  ${DIM} Ping received     ${NC}   "
                        ;;
                    ID:*)
                        # Caller ID received (save but don't print — already in header)
                        local remote_addr="${line#ID:}"
                        echo "$remote_addr" > "$remote_id_file"
                        ;;
                    MSG:*)
                        # Encrypted text message received
                        local msg_b64="${line#MSG:}"
                        local _mid=$(uid)
                        local msg_enc="$AUDIO_DIR/msg_enc_${_mid}.bin"
                        local msg_dec="$AUDIO_DIR/msg_dec_${_mid}.txt"
                        echo "$msg_b64" | base64 -d > "$msg_enc" 2>/dev/null || true
                        if [ -s "$msg_enc" ]; then
                            if decrypt_file "$msg_enc" "$msg_dec" 2>/dev/null; then
                                local msg_text
                                msg_text=$(cat "$msg_dec" 2>/dev/null)
                                echo -e "\r\n  ${MAGENTA}${BOLD}[MSG]${NC} ${WHITE}${msg_text}${NC}" >&2
                            fi
                        fi
                        rm -f "$msg_enc" "$msg_dec" 2>/dev/null
                        ;;
                    AUDIO:*)
                        # Extract base64 data, decode, decrypt, play
                        local b64_data="${line#AUDIO:}"
                        local _rid=$(uid)
                        local enc_file="$AUDIO_DIR/recv_enc_${_rid}.opus"
                        local dec_file="$AUDIO_DIR/recv_dec_${_rid}.opus"

                        echo "$b64_data" | base64 -d > "$enc_file" 2>/dev/null || true
                        if [ -s "$enc_file" ]; then
                            if decrypt_file "$enc_file" "$dec_file" 2>/dev/null; then
                                play_chunk "$dec_file" 2>/dev/null || true
                            fi
                        fi
                        rm -f "$enc_file" "$dec_file" 2>/dev/null
                        ;;
                    HANGUP)
                        # Remote party hung up
                        echo -e "\r\n\r\n  ${YELLOW}${BOLD}Remote party hung up.${NC}" >&2
                        rm -f "$CONNECTED_FLAG"
                        break
                        ;;
                esac
            else
                # Pipe closed or error — connection lost
                echo -e "\r\n\r\n  ${RED}${BOLD}Connection lost.${NC}" >&2
                rm -f "$CONNECTED_FLAG"
                break
            fi
        done
    ) &
    local recv_pid=$!
    save_pid "recv_loop" "$recv_pid"

    # Main PTT input loop
    ORIGINAL_STTY=$(stty -g)
    stty raw -echo -icanon min 0 time 1

    REC_PID=""
    REC_FILE=""
    local ptt_active=0

    if [ $IS_TERMUX -eq 1 ]; then
        echo -ne "\r  ${GREEN}${BOLD} Ready ${NC} ${DIM}[SPACE]=Talk [T]=Chat [Q]=Hang up${NC}   " >&2
    else
        echo -ne "\r  ${GREEN}${BOLD} Ready ${NC} ${DIM}[SPACE]=Hold to Talk [T]=Chat [Q]=Hang up${NC}   " >&2
    fi

    while [ -f "$CONNECTED_FLAG" ]; do
        local key=""
        key=$(dd bs=1 count=1 2>/dev/null) || true

        if [ "$key" = " " ]; then
            if [ $IS_TERMUX -eq 1 ]; then
                # TERMUX: Toggle mode
                if [ $ptt_active -eq 0 ]; then
                    ptt_active=1
                    echo -ne "\r  ${BG_RED}${WHITE}${BOLD} ● RECORDING ${NC} ${DIM}[SPACE]=Send${NC}        " >&2
                    start_recording
                else
                    ptt_active=0
                    stop_and_send
                    echo "PTT_STOP" >&4 2>/dev/null || true
                    echo -ne "\r  ${GREEN}${BOLD} Sent! ${NC} ${DIM}[SPACE]=Talk [T]=Chat [Q]=Hang up${NC}   " >&2
                fi
            else
                # LINUX: Hold-to-talk
                if [ $ptt_active -eq 0 ]; then
                    ptt_active=1
                    echo -ne "\r  ${BG_RED}${WHITE}${BOLD}${BLINK} ● RECORDING ${NC}                " >&2
                    start_recording
                fi
            fi

        elif [ "$key" = "q" ] || [ "$key" = "Q" ]; then
            # If recording, cancel it
            if [ $ptt_active -eq 1 ] && [ -n "$REC_PID" ]; then
                if [ $IS_TERMUX -eq 1 ]; then
                    termux-microphone-record -q &>/dev/null || true
                fi
                kill "$REC_PID" 2>/dev/null || true
                wait "$REC_PID" 2>/dev/null || true
                rm -f "$REC_FILE" 2>/dev/null
                REC_PID=""
                REC_FILE=""
            fi
            echo -e "\r\n${YELLOW}Hanging up...${NC}" >&2
            echo "HANGUP" >&4 2>/dev/null || true
            rm -f "$PTT_FLAG" "$CONNECTED_FLAG"
            break

        elif [ -z "$key" ]; then
            # No key pressed (timeout) — on Linux, release = stop and send
            if [ $IS_TERMUX -eq 0 ] && [ $ptt_active -eq 1 ]; then
                ptt_active=0
                stop_and_send
                echo "PTT_STOP" >&4 2>/dev/null || true
                echo -ne "\r  ${GREEN}${BOLD} Sent! ${NC} ${DIM}[SPACE]=Hold to Talk [T]=Chat [Q]=Hang up${NC}   " >&2
            fi

        elif [ "$key" = "t" ] || [ "$key" = "T" ]; then
            # Text chat mode
            # Switch to cooked mode for text input
            stty "$ORIGINAL_STTY" 2>/dev/null || stty sane
            echo -e "\r                                                              " >&2
            echo -ne "  ${CYAN}${BOLD}MSG>${NC} " >&2
            local chat_msg=""
            read -r chat_msg
            if [ -n "$chat_msg" ]; then
                # Encrypt and send
                local _cid=$(uid)
                local chat_plain="$AUDIO_DIR/chat_${_cid}.txt"
                local chat_enc="$AUDIO_DIR/chat_enc_${_cid}.bin"
                echo -n "$chat_msg" > "$chat_plain"
                encrypt_file "$chat_plain" "$chat_enc" 2>/dev/null
                if [ -s "$chat_enc" ]; then
                    local chat_b64
                    chat_b64=$(base64 -w 0 "$chat_enc" 2>/dev/null)
                    echo "MSG:${chat_b64}" >&4 2>/dev/null || true
                    echo -e "  ${DIM}[you] ${chat_msg}${NC}" >&2
                fi
                rm -f "$chat_plain" "$chat_enc" 2>/dev/null
            fi
            # Switch back to raw mode for PTT
            stty raw -echo -icanon min 0 time 1
            echo "" >&2
            if [ $IS_TERMUX -eq 1 ]; then
                echo -ne "  ${GREEN}${BOLD} Ready ${NC} ${DIM}[SPACE]=Talk [T]=Chat [Q]=Hang up${NC}   " >&2
            else
                echo -ne "  ${GREEN}${BOLD} Ready ${NC} ${DIM}[SPACE]=Hold to Talk [T]=Chat [Q]=Hang up${NC}   " >&2
            fi
        fi
    done

    # Restore terminal
    stty "$ORIGINAL_STTY" 2>/dev/null || stty sane
    ORIGINAL_STTY=""

    # Close pipe fds FIRST to unblock any blocking reads
    rm -f "$PTT_FLAG" "$CONNECTED_FLAG"
    exec 3<&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true

    # Now kill background processes (they'll exit since fds are closed)
    kill "$recv_pid" 2>/dev/null || true
    if [ -n "$REC_PID" ]; then
        kill "$REC_PID" 2>/dev/null || true
    fi
    # Brief wait, don't hang forever
    sleep 0.5
    wait "$recv_pid" 2>/dev/null || true

    CALL_ACTIVE=0
    rm -f "$remote_id_file"
    echo -e "\n${BOLD}${RED} CALL ENDED ${NC}\n"
}

#=============================================================================
# AUDIO TEST (LOOPBACK)
#=============================================================================

test_audio() {
    echo -e "\n${BOLD}${CYAN}═══ Audio Loopback Test ═══${NC}\n"

    # Check dependencies first
    local missing=0
    local audio_deps=(opusenc opusdec)
    if [ $IS_TERMUX -eq 1 ]; then
        audio_deps+=(termux-microphone-record ffmpeg)
    else
        audio_deps+=(arecord aplay)
    fi
    for dep in "${audio_deps[@]}"; do
        if ! check_dep "$dep"; then
            log_err "$dep not found — run option 7 to install dependencies first"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        return 1
    fi

    echo -e "  ${DIM}This will record 3 seconds of audio, encode it with Opus,${NC}"
    echo -e "  ${DIM}and play it back to verify your audio pipeline works.${NC}\n"

    mkdir -p "$AUDIO_DIR"

    # Step 1: Record
    echo -ne "  ${YELLOW}● Recording for 3 seconds... speak now!${NC} "
    local _tid=$(uid)
    local raw_file="$AUDIO_DIR/test_${_tid}.raw"
    audio_record "$raw_file" 3
    echo -e "${GREEN}done${NC}"

    if [ ! -s "$raw_file" ]; then
        log_err "Recording failed — check your microphone"
        return 1
    fi

    local raw_size
    raw_size=$(stat -c%s "$raw_file")
    echo -e "  ${DIM}Recorded $raw_size bytes of raw audio${NC}"

    # Step 2: Encode with Opus
    echo -ne "  ${YELLOW}● Encoding with Opus at ${OPUS_BITRATE}kbps...${NC} "
    local opus_file="$AUDIO_DIR/test_${_tid}.opus"
    opusenc --raw --raw-rate "$SAMPLE_RATE" --raw-chan 1 \
        --bitrate "$OPUS_BITRATE" --framesize "$OPUS_FRAMESIZE" \
        --speech --quiet \
        "$raw_file" "$opus_file" 2>/dev/null
    echo -e "${GREEN}done${NC}"

    if [ ! -s "$opus_file" ]; then
        log_err "Opus encoding failed"
        rm -f "$raw_file"
        return 1
    fi

    local opus_size
    opus_size=$(stat -c%s "$opus_file")
    echo -e "  ${DIM}Opus size: $opus_size bytes (compression ratio: $((raw_size / opus_size))x)${NC}"

    # Step 3: Encrypt + Decrypt round-trip (if secret is set)
    if [ -n "$SHARED_SECRET" ]; then
        echo -ne "  ${YELLOW}● Encrypting and decrypting...${NC} "
        local enc_file="$AUDIO_DIR/test_enc_${_tid}.opus"
        local dec_file="$AUDIO_DIR/test_dec_${_tid}.opus"
        encrypt_file "$opus_file" "$enc_file"
        decrypt_file "$enc_file" "$dec_file"

        if cmp -s "$opus_file" "$dec_file"; then
            echo -e "${GREEN}encryption round-trip OK${NC}"
        else
            echo -e "${RED}encryption round-trip FAILED${NC}"
        fi
        rm -f "$enc_file"
        opus_file="$dec_file"
    fi

    # Step 4: Decode and play
    echo -ne "  ${YELLOW}● Playing back...${NC} "
    play_chunk "$opus_file"
    echo -e "${GREEN}done${NC}"

    rm -f "$raw_file" "$opus_file" "$AUDIO_DIR/test_dec_${_tid}.opus" 2>/dev/null

    echo -e "\n  ${GREEN}${BOLD}Audio test complete!${NC}"
    echo -e "  ${DIM}If you heard your voice, the pipeline is working.${NC}\n"
}

#=============================================================================
# SHOW STATUS
#=============================================================================

show_status() {
    echo -e "\n${BOLD}${CYAN}═══ Status ═══${NC}\n"

    # Tor status
    if [ -n "$TOR_PID" ] && kill -0 "$TOR_PID" 2>/dev/null; then
        echo -e "  ${GREEN}●${NC} Tor running (PID $TOR_PID)"
        local onion
        onion=$(get_onion)
        if [ -n "$onion" ]; then
            echo -e "  ${BOLD}${WHITE}  Address: ${onion}${NC}"
        fi
    else
        echo -e "  ${RED}●${NC} Tor not running"
    fi

    # Secret
    if [ -n "$SHARED_SECRET" ]; then
        echo -e "  ${GREEN}●${NC} Shared secret set"
    else
        echo -e "  ${RED}●${NC} No shared secret (set one before calling)"
    fi

    # Audio
    if check_dep arecord && check_dep opusenc; then
        echo -e "  ${GREEN}●${NC} Audio pipeline ready"
    else
        echo -e "  ${RED}●${NC} Audio dependencies missing"
    fi

    # Config
    echo -e "\n  ${DIM}Listen port: $LISTEN_PORT${NC}"
    echo -e "  ${DIM}SOCKS port:  $TOR_SOCKS_PORT${NC}"
    echo -e "  ${DIM}Opus bitrate: ${OPUS_BITRATE}kbps${NC}"
    echo -e "  ${DIM}PTT key:     [SPACEBAR]${NC}"
    echo ""
}

#=============================================================================
# MAIN MENU
#=============================================================================

show_banner() {
    clear
    echo ""
    echo -e "${BOLD}${TOR_PURPLE}   ╔╦╗┌─┐┬─┐┌┬┐┬┌┐┌┌─┐┬  ╔═╗┬ ┬┌─┐┌┐┌┌─┐${NC}"
    echo -e "${BOLD}${TOR_PURPLE}    ║ ├┤ ├┬┘│││││││├─┤│  ╠═╝├─┤│ ││││├┤ ${NC}"
    echo -e "${BOLD}${TOR_PURPLE}    ╩ └─┘┴└─┴ ┴┴┘└┘┴ ┴┴─┘╩  ┴ ┴└─┘┘└┘└─┘${NC}"
    echo ""
    echo -e "  ${TOR_PURPLE}───────────────────────────────────────${NC}"
    echo -e "  ${TOR_PURPLE}${BOLD}Encrypted Voice & Chat${NC} ${DIM}over${NC} ${TOR_PURPLE}${BOLD}Tor${NC} ${DIM}Hidden Services${NC}"
    echo -e "  ${TOR_PURPLE}───────────────────────────────────────${NC}"
    echo -e "  ${DIM}v${VERSION} | Push-to-Talk | End-to-End AES-256${NC}\n"
}

main_menu() {
    while true; do
        show_banner

        # Show quick status line
        local tor_status="${RED}●${NC}"
        if [ -n "$TOR_PID" ] && kill -0 "$TOR_PID" 2>/dev/null; then
            tor_status="${GREEN}●${NC}"
        fi
        local secret_status="${RED}●${NC}"
        if [ -n "$SHARED_SECRET" ]; then
            secret_status="${GREEN}●${NC}"
        fi

        echo -e "  ${DIM}Tor:${NC} $tor_status  ${DIM}Secret:${NC} $secret_status  ${DIM}PTT:${NC} ${GREEN}[SPACE]${NC}\n"

        echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} Listen for calls"
        echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} Call an onion address"
        echo -e "  ${BOLD}${WHITE}3${NC} ${CYAN}│${NC} Show my onion address"
        echo -e "  ${BOLD}${WHITE}4${NC} ${CYAN}│${NC} Set shared secret"
        echo -e "  ${BOLD}${WHITE}5${NC} ${CYAN}│${NC} Test audio (loopback)"
        echo -e "  ${BOLD}${WHITE}6${NC} ${CYAN}│${NC} Show status"
        echo -e "  ${BOLD}${WHITE}7${NC} ${CYAN}│${NC} Install dependencies"
        echo -e "  ${BOLD}${WHITE}8${NC} ${CYAN}│${NC} Start Tor"
        echo -e "  ${BOLD}${WHITE}9${NC} ${CYAN}│${NC} Stop Tor"
        echo -e "  ${BOLD}${WHITE}10${NC}${CYAN}│${NC} Restart Tor"
        echo -e "  ${BOLD}${WHITE}11${NC}${CYAN}│${NC} Rotate onion address"
        echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${RED}Quit${NC}"
        echo ""
        echo -ne "  ${BOLD}Select: ${NC}"

        read -r choice

        case "$choice" in
            1) listen_for_call ;;
            2) call_remote ;;
            3)
                local onion
                onion=$(get_onion)
                if [ -n "$onion" ]; then
                    echo -e "\n  ${BOLD}${GREEN}Your address:${NC} ${WHITE}${BOLD}${onion}${NC}\n"
                else
                    echo -e "\n  ${YELLOW}Tor hidden service not running. Start Tor first (option 8).${NC}\n"
                fi
                echo -ne "  ${DIM}Press Enter to continue...${NC}"
                read -r
                ;;
            4) set_shared_secret ;;
            5) test_audio
               echo -ne "  ${DIM}Press Enter to continue...${NC}"
               read -r
               ;;
            6) show_status
               echo -ne "  ${DIM}Press Enter to continue...${NC}"
               read -r
               ;;
            7) install_deps
               echo -ne "\n  ${DIM}Press Enter to continue...${NC}"
               read -r
               ;;
            8)
                start_tor
                echo -ne "\n  ${DIM}Press Enter to continue...${NC}"
                read -r
                ;;
            9)
                stop_tor
                echo -ne "\n  ${DIM}Press Enter to continue...${NC}"
                read -r
                ;;
            10)
                stop_tor
                start_tor
                echo -ne "\n  ${DIM}Press Enter to continue...${NC}"
                read -r
                ;;
            11)
                rotate_onion
                echo -ne "\n  ${DIM}Press Enter to continue...${NC}"
                read -r
                ;;
            0|q|Q)
                echo -e "\n${GREEN}Goodbye!${NC}"
                stop_tor
                cleanup
                exit 0
                ;;
            *)
                echo -e "\n  ${RED}Invalid choice${NC}"
                sleep 1
                ;;
        esac
    done
}

#=============================================================================
# ENTRY POINT
#=============================================================================

trap cleanup EXIT INT TERM

# Create data directories
mkdir -p "$DATA_DIR" "$AUDIO_DIR" "$PID_DIR" "$DATA_DIR/run"

# Clean any stale run files from previous sessions
rm -f "$DATA_DIR/run/"* 2>/dev/null || true

# Load saved config
load_config

# Handle command-line arguments
case "${1:-}" in
    install)
        install_deps
        ;;
    test)
        test_audio
        ;;
    status)
        show_status
        ;;
    listen)
        load_config
        listen_for_call
        ;;
    call)
        load_config
        if [ -n "${2:-}" ]; then
            remote_onion="$2"
            if [[ "$remote_onion" != *.onion ]]; then
                remote_onion="${remote_onion}.onion"
            fi
            start_tor
            call_remote
        else
            echo "Usage: $0 call <onion-address>"
        fi
        ;;
    help|-h|--help)
        echo -e "${BOLD}${APP_NAME} v${VERSION}${NC}"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  (none)     Interactive menu"
        echo "  install    Install dependencies"
        echo "  test       Run audio loopback test"
        echo "  status     Show current status"
        echo "  listen     Start listening for calls"
        echo "  call ADDR  Call an onion address"
        echo "  help       Show this help"
        ;;
    *)
        main_menu
        ;;
esac
