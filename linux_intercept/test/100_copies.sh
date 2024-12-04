#!/bin/bash

# Set the source and target directories
SOURCE_DIR="/home/denicon/projects/Study/MagDiploma/linux_intercept/test/input_videos"
TARGET_DIR="/home/denicon/projects/Study/MagDiploma/linux_intercept/test/output_copies"

# Check if the source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
  echo "Source directory does not exist: $SOURCE_DIR"
  exit 1
fi

# Check if the target directory exists, create it if not
if [ ! -d "$TARGET_DIR" ]; then
  echo "Target directory does not exist. Creating: $TARGET_DIR"
  mkdir -p "$TARGET_DIR"
else
  echo "Target directory exist. Cleaning it: $TARGET_DIR"
  rm -r "$TARGET_DIR"
  mkdir -p "$TARGET_DIR"
fi

# Iterate over the files in the source directory
for file in "$SOURCE_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Copying $file to $TARGET_DIR"
    /usr/bin/cp "$file" "$TARGET_DIR"
  else
    echo "Skipping non-regular file: $file"
  fi
done

echo "Copy operation completed."
