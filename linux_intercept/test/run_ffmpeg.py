#!/usr/bin/env python3

import os
import subprocess
import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from multiprocessing import cpu_count

input_dir = "test/input_videos_full"
output_dir = "test/processed_videos"

def resize_video(input_file):
    shutil.rmtree(output_dir, True)
    os.makedirs(output_dir, exist_ok=True)

    # Set output file path
    output_file = os.path.join(output_dir, os.path.basename(input_file))

    # Command to resize video to 720p using ffmpeg
    command = [
        "ffmpeg",
        "-threads",
        "1",
        "-i",
        input_file,
        "-vf",
        "scale=640:480",  # Resize to 480p, preserving aspect ratio
        "-c:v",
        "libx264",  # Video codec
        "-preset",
        "fast",  # Speed preset for encoding
        "-c:a",
        "copy",  # Copy audio without re-encoding
        "-threads",
        "1",
        output_file,
    ]

    try:
        subprocess.run(command, check=True)
        print(f"Processed {input_file} -> {output_file}")
    except subprocess.CalledProcessError as e:
        print(f"Error processing {input_file}: {e}")


def main():
    # Define input video directory
    shutil.rmtree(output_dir, True)

    # Gather all video files
    video_files = [
        os.path.join(input_dir, f)
        for f in os.listdir(input_dir)
        if f.endswith((".mp4", ".avi", ".mkv"))
    ]

    # Define the number of threads, often optimal to match CPU cores
    max_threads = cpu_count()

    # Use ThreadPoolExecutor for managing ffmpeg commands in a limited number of threads
    with ThreadPoolExecutor(max_workers=max_threads) as executor:
        # Submit tasks to the executor
        futures = {executor.submit(resize_video, file): file for file in video_files}

        # Optionally handle completion as they finish
        for future in as_completed(futures):
            file = futures[future]
            try:
                future.result()
            except Exception as e:
                print(f"Error processing {file}: {e}")


if __name__ == "__main__":
    main()
