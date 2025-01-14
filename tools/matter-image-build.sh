#!/bin/bash

# Sample machine list
MACHINE_LIST="\
 imx93evk-iwxxx-matter \
 imx91evk-iwxxx-matter \
 imx8mmevk-matter \
 imx8mpevk-matter \
 imx8mnevk-matter \
 imx8mnddr3levk-matter \
 imx8ulpevk \
 imx6ullevk \
"

CODEBASE="${CODEBASE:-}"
SCP_TARGET_PATH="${SCP_TARGET_PATH:-}"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log file setup
LOG_FILE="${CODEBASE}/build_$(date '+%Y%m%d_%H%M%S').log"
SEPARATOR="================================================================"

# Format duration function
format_duration() {
    local duration=$1
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    printf "%02d:%02d:%02d" $hours $minutes $seconds
}

# Progress bar function
show_progress() {
    local current=$1
    local total=$2
    local width=50    # Progress bar width
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local unfilled=$((width - filled))

    # Create the progress bar
    printf "\rProgress: ["
    printf "%${filled}s" | tr ' ' '#'
    printf "%${unfilled}s" | tr ' ' '-'
    printf "] %d/%d (%d%%)" "$current" "$total" "$percentage"
}

# Simple log function without color processing
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color_level=""

    # Set color for different log levels
    case $level in
        "INFO")    color_level="${BLUE}INFO${NC}" ;;
        "SUCCESS") color_level="${GREEN}SUCCESS${NC}" ;;
        "WARNING") color_level="${YELLOW}WARNING${NC}" ;;
        "ERROR")   color_level="${RED}ERROR${NC}" ;;
    esac

    # Output to console with color
    echo -e "${CYAN}${timestamp}${NC} [${color_level}] ${message}"

    # Output to log file without color codes
    echo "${timestamp} [${level}] ${message}" >> "${LOG_FILE}"
}

# Scp the image to target folder if needed
copy_images() {
    if [ -z "${SCP_TARGET_PATH}" ]; then
        log "INFO" "Skipping copying as SCP_TARGET_PATH is not set"
        return 0
    fi

    log "INFO" "Starting to copy all built images"
    local failed_copies=""

    for machine_name in ${MACHINE_LIST}; do
        local image_path="${CODEBASE}/bld-xwayland-${machine_name}/tmp/deploy/images/${machine_name}/imx-image-multimedia-${machine_name}.rootfs.wic.zst"
        log "INFO" "Copying image to target location for ${RED}${machine_name}${NC}"

        if ! scp "${image_path}" "${SCP_TARGET_PATH}"; then
            log "ERROR" "Failed to copy image for ${RED}${machine_name}${NC} to target location"
            failed_copies="${failed_copies} ${machine_name}"
        else
            log "SUCCESS" "Image copied successfully for ${RED}${machine_name}${NC}"
        fi
    done

    if [ -n "${failed_copies}" ]; then
        log "WARNING" "Failed copies: ${RED}${failed_copies}${NC}"
        return 1
    fi

    log "SUCCESS" "All images copied successfully"
    return 0
}

# Build function
build_machine() {
    local machine_name=$1
    local build_start_time=$(date '+%Y-%m-%d %H:%M:%S')
    local build_start_seconds=$(date +%s)

    log "INFO" "Starting build for ${RED}${machine_name}${NC} at ${build_start_time}"

    # Change to codebase directory
    cd "${CODEBASE}" || {
        log "ERROR" "Failed to change directory to ${CODEBASE}"
        return 1
    }

    # Setup environment
    log "INFO" "Setting up build environment for ${RED}${machine_name}${NC}"
    EULA=1 MACHINE="${machine_name}" DISTRO=fsl-imx-xwayland \
    source sources/meta-nxp-connectivity/tools/imx-matter-setup.sh "bld-xwayland-${machine_name}" >> "${LOG_FILE}" 2>&1

    if [ $? -ne 0 ]; then
        log "ERROR" "Environment setup failed for ${machine_name}"
        return 1
    fi

    # Source additional setup for NXP internal build. External build please remove this line.
    source ../sources/imx-build-bamboo/build/hook-in-internal-servers.sh >> "${LOG_FILE}" 2>&1

    # Build image with progress bar
    log "INFO" "Building imx-image-multimedia for ${RED}${machine_name}${NC}"

    local temp_output=$(mktemp)

    bitbake imx-image-multimedia 2>&1 | tee "${temp_output}" | while read line; do
        # Capture progress information
        if [[ $line =~ "Running task "([0-9]+)" of "([0-9]+) ]]; then
            current_task=${BASH_REMATCH[1]}
            total_tasks=${BASH_REMATCH[2]}
            show_progress "$current_task" "$total_tasks"
        fi
        echo "$line" >> "${LOG_FILE}"
    done

    # Check the actual bitbake exit status
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo    # New line after progress bar
        log "ERROR" "Build failed for ${RED}${machine_name}${NC}"
        return 1
    fi

    echo    # New line after progress bar

    # Calculate build duration
    local build_end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local build_end_seconds=$(date +%s)
    local build_duration=$((build_end_seconds - build_start_seconds))
    local formatted_duration=$(format_duration $build_duration)

    log "SUCCESS" "Build completed for ${RED}${machine_name}${NC}"
    log "INFO" "Build duration for ${RED}${machine_name}${NC}: ${GREEN}${formatted_duration}${NC} (Start: ${build_start_time}, End: ${build_end_time})"

    return 0
}

# Main build loop
total_machines=$(echo "${MACHINE_LIST}" | wc -w)
current_machine=0
failed_machines=""
script_start_time=$(date +%s)

# First phase: Build all machines
for machine_name in ${MACHINE_LIST}; do
    current_machine=$((current_machine + 1))
    log "INFO" "Processing machine ${current_machine}/${total_machines}: ${RED}${machine_name}${NC}"
    echo "${SEPARATOR}" >> "${LOG_FILE}"

    if build_machine "${machine_name}"; then
        log "INFO" "Successfully processed ${RED}${machine_name}${NC}"
    else
        failed_machines="${failed_machines} ${machine_name}"
        log "WARNING" "Failed to process ${RED}${machine_name}${NC}"
    fi

    echo "${SEPARATOR}" >> "${LOG_FILE}"
done

# Calculate build duration
script_end_time=$(date +%s)
total_duration=$((script_end_time - script_start_time))
formatted_total_duration=$(format_duration $total_duration)

# Build summary
log "INFO" "Build process completed"
log "INFO" "Total build time: ${formatted_total_duration}"
if [ -n "${failed_machines}" ]; then
    log "WARNING" "Failed builds:${failed_machines}"
else
    log "SUCCESS" "All builds completed successfully"
fi

# Second phase: Copy all images
if [ -z "${failed_machines}" ]; then
    log "INFO" "Starting image copy phase"
    copy_images
else
    log "WARNING" "Skipping image copy phase due to build failures"
fi

echo "${SEPARATOR}" >> "${LOG_FILE}"
log "INFO" "Log file location: ${LOG_FILE}"
