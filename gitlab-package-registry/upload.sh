#!/bin/bash

# Script to upload files to a GitLab Generic Package Registry
# Can supply an individual file or a directory. By default uploads all files in a specified directory.

# Default configuration (can be overridden by environment variables)
TOKEN="${PRIVATE_TOKEN:-<access_token>}"
PROJECT_ID="${GITLAB_PROJECT_ID:-24}"
PACKAGE_NAME="${PACKAGE_NAME:-my_package}"
PACKAGE_VERSION="${PACKAGE_VERSION:-1.0.0}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.example.com}"
TARGET_PATH="${1:-./files_to_upload}"

if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_file_or_directory>"
    echo "Using default target path: $TARGET_PATH"
fi

upload_file() {
    local file_path="$1"
    local filename=$(basename "$file_path")
    local url="${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/packages/generic/${PACKAGE_NAME}/${PACKAGE_VERSION}/${filename}"

    echo "Uploading: $filename to $url"
    
    # Using curl to upload the file
    curl --location \
         --header "PRIVATE-TOKEN: $TOKEN" \
         --upload-file "$file_path" \
         "$url"
         
    echo -e "\nFinished uploading: $filename\n"
}

if [ -d "$TARGET_PATH" ]; then
    echo "Target is a directory. Uploading all files in directory..."
    for file in "${TARGET_PATH}"/*; do
        if [ -f "$file" ]; then
            upload_file "$file"
        fi
    done
elif [ -f "$TARGET_PATH" ]; then
    echo "Target is a file. Uploading..."
    upload_file "$TARGET_PATH"
else
    echo "Error: $TARGET_PATH is not a valid file or directory."
    exit 1
fi