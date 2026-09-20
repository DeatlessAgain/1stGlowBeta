"""
Sample Python client to test the FastAPI /extract endpoint.
Usage:
    python test_client.py
"""

import sys
import httpx

API_BASE = "http://localhost:8000"
TEST_URL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"


def test_extraction(video_url: str):
    print(f"\n[+] Requesting format extraction for:\n    {video_url}\n")
    try:
        response = httpx.get(
            f"{API_BASE}/extract",
            params={"url": video_url},
            timeout=30.0,
        )

        if response.status_code == 200:
            data = response.json()
            print("=" * 60)
            print(f"TITLE:    {data.get('title')}")
            print(f"UPLOADER: {data.get('uploader')}")
            print(f"DURATION: {data.get('duration_formatted')} ({data.get('duration')}s)")
            print(f"TOTAL FORMATS: {data.get('total_formats')}")
            print("=" * 60)

            print("\n--- TOP VIDEO FORMATS ---")
            for f in data.get("video_formats", [])[:5]:
                size = f.get("filesize_readable") or "N/A"
                print(
                    f"[{f['format_id']}] {f['ext'].upper():<4} | "
                    f"Quality: {f['quality_label']:<10} | "
                    f"Res: {f.get('resolution', 'N/A'):<10} | "
                    f"Size: {size:<9} | URL: {f['url'][:60]}..."
                )

            print("\n--- TOP AUDIO FORMATS ---")
            for f in data.get("audio_formats", [])[:3]:
                size = f.get("filesize_readable") or "N/A"
                print(
                    f"[{f['format_id']}] {f['ext'].upper():<4} | "
                    f"Bitrate: {f.get('abr', 'N/A')} kbps | "
                    f"Codec: {f.get('acodec', 'N/A'):<8} | "
                    f"Size: {size:<9} | URL: {f['url'][:60]}..."
                )

        else:
            print(f"[-] Request failed with status code {response.status_code}")
            print(f"[-] Detail: {response.text}")

    except httpx.ConnectError:
        print("[-] Could not connect to FastAPI server.")
        print("[-] Ensure the server is running with: uvicorn main:app --reload")


if __name__ == "__main__":
    url_arg = sys.argv[1] if len(sys.argv) > 1 else TEST_URL
    test_extraction(url_arg)
