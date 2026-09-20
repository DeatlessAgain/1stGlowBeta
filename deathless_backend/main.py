"""
FastAPI Backend for Media Format Extraction using yt-dlp.

Features:
- GET /extract endpoint accepting a ?url= query parameter
- Non-blocking execution using asyncio.to_thread for thread-safe yt-dlp operations
- Extraction of video and audio formats with direct download URLs, resolutions, extensions, and file sizes
- Comprehensive exception handling for invalid URLs, unsupported hosts, and private/deleted media
- Pydantic models for OpenAPI documentation and response validation
- CORS middleware for cross-origin frontend support
"""

import asyncio
import re
from typing import Any, Dict, List, Optional
from urllib.parse import urlparse

from fastapi import FastAPI, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import yt_dlp
from yt_dlp.utils import (
    DownloadError,
    ExtractorError,
    GeoRestrictedError,
    UnavailableVideoError,
    UnsupportedUrlError,
)

# -----------------------------------------------------------------------------
# FastAPI Application Initialization
# -----------------------------------------------------------------------------
app = FastAPI(
    title="Deathless Downloader API",
    description=(
        "Deathless Downloader FastAPI service that extracts video and audio streams, quality resolutions, "
        "direct download URLs, and metadata from supported media URLs using yt-dlp."
    ),
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# Enable CORS for frontend applications and web clients
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# -----------------------------------------------------------------------------
# Pydantic Response & Data Models
# -----------------------------------------------------------------------------
class FormatItem(BaseModel):
    format_id: str = Field(..., description="Unique format identifier from the extractor")
    format_note: Optional[str] = Field(None, description="Quality note (e.g. 1080p60, medium, tiny)")
    ext: str = Field(..., description="File extension (e.g. mp4, webm, m4a)")
    resolution: Optional[str] = Field(None, description="Video resolution string, e.g. 1920x1080 or audio only")
    width: Optional[int] = Field(None, description="Width in pixels (for video)")
    height: Optional[int] = Field(None, description="Height in pixels (for video)")
    fps: Optional[float] = Field(None, description="Frames per second")
    vcodec: Optional[str] = Field(None, description="Video codec name")
    acodec: Optional[str] = Field(None, description="Audio codec name")
    filesize: Optional[int] = Field(None, description="Exact file size in bytes if known")
    filesize_approx: Optional[int] = Field(None, description="Approximate file size in bytes")
    filesize_readable: Optional[str] = Field(None, description="Human-readable file size (e.g. 45.2 MB)")
    tbr: Optional[float] = Field(None, description="Total average bitrate in kbps")
    vbr: Optional[float] = Field(None, description="Video bitrate in kbps")
    abr: Optional[float] = Field(None, description="Audio bitrate in kbps")
    asr: Optional[int] = Field(None, description="Audio sampling rate in Hz")
    url: str = Field(..., description="Direct download or streaming playback URL")
    has_video: bool = Field(..., description="Whether this format contains a video track")
    has_audio: bool = Field(..., description="Whether this format contains an audio track")
    is_video_only: bool = Field(..., description="True if only video (DASH/separate video stream)")
    is_audio_only: bool = Field(..., description="True if only audio stream")
    is_combined: bool = Field(..., description="True if both video and audio are packaged together")
    quality_label: Optional[str] = Field(None, description="Formatted display quality label")


class ExtractionResponse(BaseModel):
    status: str = Field("success", description="Response status")
    url: str = Field(..., description="The original request media URL")
    id: str = Field(..., description="Media identifier from the provider")
    title: str = Field(..., description="Title of the media")
    description: Optional[str] = Field(None, description="Brief description or excerpt")
    uploader: Optional[str] = Field(None, description="Channel, artist, or uploader name")
    uploader_url: Optional[str] = Field(None, description="URL of the uploader profile/channel")
    channel_id: Optional[str] = Field(None, description="Channel ID if available")
    duration: Optional[int] = Field(None, description="Duration in total seconds")
    duration_formatted: Optional[str] = Field(None, description="Formatted duration string (HH:MM:SS)")
    view_count: Optional[int] = Field(None, description="Total view count")
    thumbnail: Optional[str] = Field(None, description="Primary thumbnail image URL")
    webpage_url: Optional[str] = Field(None, description="Canonical webpage URL")
    extractor: Optional[str] = Field(None, description="yt-dlp extractor name (e.g. youtube, vimeo)")
    total_formats: int = Field(..., description="Total number of extracted valid formats")
    video_formats: List[FormatItem] = Field(default_factory=list, description="All formats containing video")
    audio_formats: List[FormatItem] = Field(default_factory=list, description="Audio-only formats")
    combined_formats: List[FormatItem] = Field(default_factory=list, description="Pre-muxed formats (both video and audio)")
    all_formats: List[FormatItem] = Field(default_factory=list, description="Complete list of all available stream formats")


class ErrorResponse(BaseModel):
    status: str = Field("error", description="Response status")
    detail: str = Field(..., description="Detailed description of the error")
    error_code: str = Field(..., description="Machine-readable error identifier")


# -----------------------------------------------------------------------------
# Helper Utilities
# -----------------------------------------------------------------------------
def format_bytes(size: Optional[int]) -> Optional[str]:
    """Convert a byte count to a human-readable string (KB, MB, GB)."""
    if size is None or size <= 0:
        return None
    units = ["B", "KB", "MB", "GB", "TB"]
    i = 0
    s = float(size)
    while s >= 1024.0 and i < len(units) - 1:
        s /= 1024.0
        i += 1
    return f"{s:.1f} {units[i]}"


def format_duration(seconds: Optional[int]) -> Optional[str]:
    """Format total seconds into MM:SS or HH:MM:SS string."""
    if seconds is None or seconds < 0:
        return None
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    if hours > 0:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def sanitize_url(raw_url: str) -> str:
    """Validate and clean the incoming URL string."""
    cleaned = raw_url.strip()
    if not cleaned:
        raise ValueError("URL parameter cannot be empty.")

    parsed = urlparse(cleaned)
    if not parsed.scheme or parsed.scheme.lower() not in ("http", "https"):
        raise ValueError("URL must have a valid 'http' or 'https' protocol scheme.")
    if not parsed.netloc:
        raise ValueError("URL must contain a valid domain / network location.")

    return cleaned


def parse_format_dict(f: Dict[str, Any]) -> Optional[FormatItem]:
    """
    Parse a single raw format dictionary from yt-dlp into a structured FormatItem.
    Only formats with accessible direct URLs are retained.
    """
    direct_url = f.get("url")
    if not direct_url:
        return None

    vcodec = f.get("vcodec")
    acodec = f.get("acodec")

    has_video = bool(vcodec and vcodec.lower() != "none")
    has_audio = bool(acodec and acodec.lower() != "none")

    is_video_only = has_video and not has_audio
    is_audio_only = has_audio and not has_video
    is_combined = has_video and has_audio

    # Skip formats with neither video nor audio
    if not has_video and not has_audio:
        return None

    width = f.get("width")
    height = f.get("height")
    fps = f.get("fps")

    # Generate resolution string
    if width and height:
        resolution = f"{width}x{height}"
    elif height:
        resolution = f"{height}p"
    elif is_audio_only:
        resolution = "Audio only"
    else:
        resolution = f.get("resolution") or "Unknown"

    # Filesize formatting
    filesize = f.get("filesize")
    filesize_approx = f.get("filesize_approx")
    size_to_format = filesize or filesize_approx
    filesize_readable = format_bytes(size_to_format)

    # Friendly quality label
    abr = f.get("abr")
    if is_audio_only and abr:
        quality_label = f"{int(abr)} kbps (Audio)"
    elif height:
        fps_suffix = f" {int(fps)}fps" if fps and fps > 30 else ""
        quality_label = f"{height}p{fps_suffix}"
    elif f.get("format_note"):
        quality_label = str(f.get("format_note"))
    else:
        quality_label = resolution

    return FormatItem(
        format_id=str(f.get("format_id", "unknown")),
        format_note=f.get("format_note"),
        ext=str(f.get("ext", "mp4")),
        resolution=resolution,
        width=width,
        height=height,
        fps=fps,
        vcodec=vcodec if vcodec != "none" else None,
        acodec=acodec if acodec != "none" else None,
        filesize=filesize,
        filesize_approx=filesize_approx,
        filesize_readable=filesize_readable,
        tbr=f.get("tbr"),
        vbr=f.get("vbr"),
        abr=abr,
        asr=f.get("asr"),
        url=direct_url,
        has_video=has_video,
        has_audio=has_audio,
        is_video_only=is_video_only,
        is_audio_only=is_audio_only,
        is_combined=is_combined,
        quality_label=quality_label,
    )


# -----------------------------------------------------------------------------
# yt-dlp Extraction Core (Blocking, wrapped for asyncio)
# -----------------------------------------------------------------------------
def run_yt_dlp_extraction(media_url: str) -> Dict[str, Any]:
    """
    Execute yt-dlp extraction synchronously with options tuned for fast metadata extraction.
    This function is intended to be called in a background thread via asyncio.to_thread.
    """
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "extract_flat": False,
        "noplaylist": True,
        "http_headers": {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"
            ),
            "Accept-Language": "en-US,en;q=0.9",
        },
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(media_url, download=False)
        return info


# -----------------------------------------------------------------------------
# API Endpoints
# -----------------------------------------------------------------------------
@app.get("/", summary="Root Health & Info")
async def root():
    """Returns basic service information and documentation links."""
    return {
        "service": "Deathless Downloader API",
        "status": "online",
        "docs": "/docs",
        "extract_endpoint": "/extract?url={media_url}",
    }


@app.get("/health", summary="Health Check")
async def health():
    """Health check endpoint for container orchestrators and load balancers."""
    return {"status": "healthy"}


@app.get(
    "/extract",
    response_model=ExtractionResponse,
    responses={
        200: {"model": ExtractionResponse, "description": "Successful format extraction"},
        400: {"model": ErrorResponse, "description": "Invalid URL or unsupported media format"},
        404: {"model": ErrorResponse, "description": "Media not found or private"},
        403: {"model": ErrorResponse, "description": "Geo-restricted or access forbidden"},
        500: {"model": ErrorResponse, "description": "Internal extractor error"},
    },
    summary="Extract Video & Audio Formats",
    description=(
        "Extracts all available video and audio streams, quality resolutions, and direct "
        "download URLs for a given media URL using yt-dlp."
    ),
)
async def extract(
    url: str = Query(
        ...,
        description="The full HTTP/HTTPS URL of the media (YouTube, Vimeo, SoundCloud, Twitter/X, TikTok, etc.)",
        example="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    )
):
    # 1. Basic URL syntax validation
    try:
        sanitized_url = sanitize_url(url)
    except ValueError as ve:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(ve),
        )

    # 2. Asynchronous execution in threadpool to avoid blocking FastAPI's event loop
    try:
        info_dict = await asyncio.to_thread(run_yt_dlp_extraction, sanitized_url)
    except UnsupportedUrlError as uue:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"The URL is not supported by yt-dlp: {str(uue)}",
        )
    except UnavailableVideoError as uve:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"The requested media is unavailable or removed: {str(uve)}",
        )
    except GeoRestrictedError as gre:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"This media is geo-restricted in the server's region: {str(gre)}",
        )
    except DownloadError as de:
        err_msg = re.sub(r"^(?:ERROR:\s*)", "", str(de))
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"yt-dlp extraction failed: {err_msg}",
        )
    except ExtractorError as ee:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Extractor error: {str(ee)}",
        )
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"An unexpected extraction error occurred: {str(exc)}",
        )

    if not info_dict:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No media information could be retrieved for the specified URL.",
        )

    # 3. Parse formats
    raw_formats = info_dict.get("formats") or []
    all_formats: List[FormatItem] = []
    video_formats: List[FormatItem] = []
    audio_formats: List[FormatItem] = []
    combined_formats: List[FormatItem] = []

    for raw_f in raw_formats:
        item = parse_format_dict(raw_f)
        if not item:
            continue

        all_formats.append(item)
        if item.has_video:
            video_formats.append(item)
        if item.is_audio_only:
            audio_formats.append(item)
        if item.is_combined:
            combined_formats.append(item)

    # Sort video formats by height/resolution descending, then bitrate
    video_formats.sort(
        key=lambda x: (x.height or 0, x.tbr or x.vbr or 0),
        reverse=True,
    )

    # Sort audio formats by audio bitrate descending
    audio_formats.sort(
        key=lambda x: (x.abr or 0, x.filesize or 0),
        reverse=True,
    )

    duration = info_dict.get("duration")

    return ExtractionResponse(
        status="success",
        url=sanitized_url,
        id=str(info_dict.get("id", "")),
        title=str(info_dict.get("title", "Untitled")),
        description=info_dict.get("description"),
        uploader=info_dict.get("uploader"),
        uploader_url=info_dict.get("uploader_url"),
        channel_id=info_dict.get("channel_id"),
        duration=duration,
        duration_formatted=format_duration(duration),
        view_count=info_dict.get("view_count"),
        thumbnail=info_dict.get("thumbnail"),
        webpage_url=info_dict.get("webpage_url") or sanitized_url,
        extractor=info_dict.get("extractor"),
        total_formats=len(all_formats),
        video_formats=video_formats,
        audio_formats=audio_formats,
        combined_formats=combined_formats,
        all_formats=all_formats,
    )


# -----------------------------------------------------------------------------
# Local Development Server Runner
# -----------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
