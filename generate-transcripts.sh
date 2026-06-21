#!/bin/bash
set -euo pipefail
# Batch-generate WebVTT caption transcripts for a folder of videos via whisper.cpp.
# Searches recursively; output is always flattened into content/videos/transcripts/
# by basename, matching lib/helpers.rb's video_transcript_path lookup convention.

# Resolve symlinks to find the real script directory
_s="${BASH_SOURCE[0]}"
while [[ -L "$_s" ]]; do _d="$(cd "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; [[ "$_s" != /* ]] && _s="$_d/$_s"; done
source "$(cd "$(dirname "$_s")" && pwd)/shared.sh"

if [[ ! -f "nanoc.yaml" ]]; then
    echo "Error: must be run from the project root (nanoc.yaml not found)"
    exit 1
fi

function print_help() {
    echo -e "Usage: ./generate-transcripts.sh <folder> [--force] [--model NAME] [--language LANG] [--dry-run] [-h|--help]

Batch-generates WebVTT (.vtt) caption transcripts for every video found
recursively under <folder>, using whisper.cpp. Output is written to
content/videos/transcripts/<video-basename>.vtt regardless of which
subfolder the source video is in.

Options:
  --force             Regenerate even if a transcript already exists
  --model NAME        whisper.cpp model name, e.g. tiny.en/base.en/small.en/medium.en (default: base.en)
  --language LANG     Spoken language code passed to whisper (default: en)
  --dry-run           List videos that would be processed, without transcribing
  -h, --help          Show this help message"
}

MODEL_NAME="base.en"
LANGUAGE="en"
FORCE=false
DRY_RUN=false
FOLDER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true
            shift
            ;;
        --model)
            MODEL_NAME="$2"
            shift 2
            ;;
        --language)
            LANGUAGE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            print_help
            exit 1
            ;;
        *)
            if [[ -n "$FOLDER" ]]; then
                echo "Unexpected extra argument: $1"
                print_help
                exit 1
            fi
            FOLDER="$1"
            shift
            ;;
    esac
done

if [[ -z "$FOLDER" ]]; then
    echo -e "${FAIL} A folder argument is required"
    print_help
    exit 1
fi

if [[ ! -d "$FOLDER" ]]; then
    echo -e "${FAIL} Folder not found: ${FOLDER}"
    exit 1
fi

TRANSCRIPTS_DIR="${current_dir}/content/videos/transcripts"
MODEL_DIR="${HOME}/.cache/whisper-models"
MODEL_PATH="${MODEL_DIR}/ggml-${MODEL_NAME}.bin"

function check_for_ffmpeg() {
    if ! command -v ffmpeg &> /dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo -e "${WARN} ffmpeg not found, installing via brew..."
            brew install ffmpeg
        else
            echo -e "${FAIL} Please install ffmpeg: https://ffmpeg.org/download.html"
            exit 2
        fi
    else
        echo -e "${PASS} ffmpeg found"
    fi
}

function check_for_whisper() {
    if ! command -v whisper-cli &> /dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo -e "${WARN} whisper-cli not found, installing via brew (whisper-cpp)..."
            brew install whisper-cpp
        else
            echo -e "${FAIL} Please install whisper.cpp: https://github.com/ggml-org/whisper.cpp"
            exit 3
        fi
    else
        echo -e "${PASS} whisper-cli found"
    fi
}

function ensure_model() {
    if [[ -f "$MODEL_PATH" ]]; then
        echo -e "${PASS} Model found: ${MODEL_PATH}"
        return
    fi
    echo -e "${WARN} Model ggml-${MODEL_NAME}.bin not cached, downloading..."
    mkdir -p "$MODEL_DIR"
    local url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"
    if curl -fL --progress-bar -o "${MODEL_PATH}.tmp" "$url"; then
        mv "${MODEL_PATH}.tmp" "$MODEL_PATH"
        echo -e "${PASS} Downloaded model to ${MODEL_PATH}"
    else
        rm -f "${MODEL_PATH}.tmp"
        echo -e "${FAIL} Failed to download model from ${url}"
        exit 4
    fi
}

# Strip any leading blank lines so the file starts exactly with the WEBVTT
# signature the spec requires (this is the exact bug found and hand-fixed in
# glyder-showcase.vtt — a stray leading newline silently breaks every cue).
function sanitise_vtt() {
    local file="$1"
    awk 'BEGIN{skip=1} skip && /^[[:space:]]*$/{next} {skip=0; print}' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

function has_cues() {
    local file="$1"
    [[ "$(head -n1 "$file")" == "WEBVTT"* ]] && grep -q -- '-->' "$file"
}

function process_video() {
    local video="$1"
    local base name target workdir wav outbase vtt
    base="$(basename "$video")"
    name="${base%.*}"
    target="${TRANSCRIPTS_DIR}/${name}.vtt"

    if [[ -f "$target" && "$FORCE" != true ]]; then
        echo -e "${PASS} Skipping (transcript exists): ${name}"
        SKIPPED_EXISTING=$((SKIPPED_EXISTING + 1))
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${WARN} [dry-run] Would transcribe: ${video}"
        return
    fi

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' RETURN
    wav="${workdir}/audio.wav"
    outbase="${workdir}/${name}"

    echo -e "${PASS} Transcribing: ${name}..."

    if ! ffmpeg -y -loglevel error -i "$video" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"; then
        echo -e "${FAIL} ffmpeg failed to extract audio from ${video}"
        FAILED=$((FAILED + 1))
        return
    fi

    if ! whisper-cli -m "$MODEL_PATH" -l "$LANGUAGE" -sns -ovtt -of "$outbase" -np -f "$wav" &> "${workdir}/whisper.log"; then
        echo -e "${FAIL} whisper-cli failed on ${video}:"
        tail -n 20 "${workdir}/whisper.log"
        FAILED=$((FAILED + 1))
        return
    fi

    vtt="${outbase}.vtt"
    if [[ -f "$vtt" ]]; then
        sanitise_vtt "$vtt"
    fi
    if [[ ! -f "$vtt" ]] || ! has_cues "$vtt"; then
        echo -e "${WARN} No speech detected, skipping transcript: ${name}"
        SKIPPED_NO_SPEECH=$((SKIPPED_NO_SPEECH + 1))
        return
    fi

    mv "$vtt" "$target"
    echo -e "${PASS} Wrote transcript: ${target}"
    GENERATED=$((GENERATED + 1))
}

check_for_ffmpeg
check_for_whisper
ensure_model
mkdir -p "$TRANSCRIPTS_DIR"

GENERATED=0
SKIPPED_EXISTING=0
SKIPPED_NO_SPEECH=0
FAILED=0
FOUND_ANY=false

while IFS= read -r -d '' video; do
    FOUND_ANY=true
    process_video "$video"
done < <(find "$FOLDER" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.webm' \) -print0 | sort -z)

if [[ "$FOUND_ANY" != true ]]; then
    echo -e "${WARN} No video files found under ${FOLDER}"
    exit 0
fi

echo ""
echo -e "${PASS} Done. Generated: ${GENERATED}, skipped (existing): ${SKIPPED_EXISTING}, skipped (no speech): ${SKIPPED_NO_SPEECH}, failed: ${FAILED}"

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
