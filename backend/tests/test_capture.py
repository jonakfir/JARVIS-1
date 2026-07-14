from __future__ import annotations

import asyncio
import base64
import io
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

from capture.frame_handler import FrameHandler
from capture.frame_handler import Identification as TrackedIdentification
from identification.models import FaceDetectionResult, FaceSearchResult
from main import app
from schemas import Identification

client = TestClient(app)


VALID_FRAME_B64 = base64.b64encode(b"not-a-real-jpeg").decode()


async def wait_for_identification(handler: FrameHandler, track_id: int) -> None:
    for _ in range(20):
        if handler._identifications[track_id].status != "identifying":
            return
        await asyncio.sleep(0)
    pytest.fail("identification task did not finish")


def test_identification_to_dict_includes_error() -> None:
    identification = TrackedIdentification(track_id=7)
    identification.status = "failed"
    identification.error = "PimEyes cookies expired"

    assert identification.to_dict() == {
        "track_id": 7,
        "status": "failed",
        "name": None,
        "person_id": None,
        "error": "PimEyes cookies expired",
    }


def test_identification_schema_serializes_optional_error() -> None:
    identification = Identification(
        track_id=7,
        status="failed",
        error="PimEyes cookies expired",
    )

    assert identification.model_dump()["error"] == "PimEyes cookies expired"


@pytest.mark.asyncio
async def test_target_uses_largest_bbox_not_largest_encoded_crop(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    handler = FrameHandler()
    detections = [
        {"bbox": [0.0, 0.0, 20.0, 20.0], "confidence": 0.99, "track_id": 1},
        {"bbox": [0.0, 0.0, 80.0, 100.0], "confidence": 0.90, "track_id": 2},
    ]
    monkeypatch.setattr(
        handler.detector,
        "detect_from_base64",
        lambda _: {"detections": detections},
    )
    monkeypatch.setattr(
        handler.detector,
        "crop_persons",
        lambda *_: ["a" * 500, "b" * 100],
    )

    await handler.process_frame(VALID_FRAME_B64, 1, "meta_glasses_ios", target=True)
    await wait_for_identification(handler, 2)

    assert handler._identifications[2].track_id == 2
    assert 1 not in handler._identifications


@pytest.mark.asyncio
async def test_target_crop_count_mismatch_does_not_start_identification(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    handler = FrameHandler()
    detections = [
        {"bbox": [0.0, 0.0, 20.0, 20.0], "confidence": 0.99, "track_id": 1},
        {"bbox": [0.0, 0.0, 80.0, 100.0], "confidence": 0.90, "track_id": 2},
    ]
    monkeypatch.setattr(
        handler.detector,
        "detect_from_base64",
        lambda _: {"detections": detections},
    )
    monkeypatch.setattr(handler.detector, "crop_persons", lambda *_: ["a-crop"])

    await handler.process_frame(VALID_FRAME_B64, 1, "meta_glasses_ios", target=True)

    assert handler._identifications == {}
    assert handler._search_in_progress is False


@pytest.mark.asyncio
async def test_missing_pipeline_releases_identification_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    handler = FrameHandler()
    detections = [
        {"bbox": [0.0, 0.0, 20.0, 20.0], "confidence": 0.99, "track_id": 1},
    ]
    monkeypatch.setattr(
        handler.detector,
        "detect_from_base64",
        lambda _: {"detections": detections},
    )
    monkeypatch.setattr(handler.detector, "crop_persons", lambda *_: [VALID_FRAME_B64])

    await handler.process_frame(VALID_FRAME_B64, 1, "meta_glasses_ios", target=True)
    await wait_for_identification(handler, 1)

    assert handler._identifications[1].error == "Face pipeline not configured"
    assert handler._search_in_progress is False


@pytest.mark.asyncio
async def test_search_failure_releases_identification_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    face_detector = MagicMock()
    face_detector.detect_faces = AsyncMock(
        return_value=FaceDetectionResult(success=False, faces=[]),
    )
    searcher = MagicMock()
    searcher.search_face = AsyncMock(
        return_value=FaceSearchResult(success=False, error="expired"),
    )
    handler = FrameHandler(
        face_detector=face_detector,
        embedder=MagicMock(),
        face_searcher=searcher,
    )
    detections = [
        {"bbox": [0.0, 0.0, 20.0, 20.0], "confidence": 0.99, "track_id": 1},
    ]
    monkeypatch.setattr(
        handler.detector,
        "detect_from_base64",
        lambda _: {"detections": detections},
    )
    monkeypatch.setattr(handler.detector, "crop_persons", lambda *_: [VALID_FRAME_B64])

    await handler.process_frame(VALID_FRAME_B64, 1, "meta_glasses_ios", target=True)
    await wait_for_identification(handler, 1)

    assert handler._identifications[1].error == "No matches found"
    assert handler._search_in_progress is False


def test_capture_upload_returns_processed() -> None:
    file = io.BytesIO(b"fake image data")
    response = client.post(
        "/api/capture",
        files={"file": ("test.jpg", file, "image/jpeg")},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] in ("processed", "error")
    assert payload["filename"] == "test.jpg"
    assert payload["content_type"] == "image/jpeg"


def test_capture_upload_returns_capture_id() -> None:
    file = io.BytesIO(b"fake image data")
    response = client.post(
        "/api/capture",
        files={"file": ("photo.png", file, "image/png")},
    )

    payload = response.json()
    assert payload["capture_id"].startswith("cap_")
    assert len(payload["capture_id"]) == 16  # "cap_" + 12 hex chars


def test_capture_upload_default_source() -> None:
    file = io.BytesIO(b"fake image data")
    response = client.post(
        "/api/capture",
        files={"file": ("test.jpg", file, "image/jpeg")},
    )

    payload = response.json()
    assert payload["source"] == "manual_upload"


def test_capture_upload_custom_source() -> None:
    file = io.BytesIO(b"fake image data")
    response = client.post(
        "/api/capture",
        files={"file": ("test.jpg", file, "image/jpeg")},
        params={"source": "telegram"},
    )

    payload = response.json()
    assert payload["source"] == "telegram"


def test_capture_upload_generates_unique_ids() -> None:
    file1 = io.BytesIO(b"data1")
    file2 = io.BytesIO(b"data2")

    r1 = client.post("/api/capture", files={"file": ("a.jpg", file1, "image/jpeg")})
    r2 = client.post("/api/capture", files={"file": ("b.jpg", file2, "image/jpeg")})

    assert r1.json()["capture_id"] != r2.json()["capture_id"]


def test_capture_upload_without_file_returns_422() -> None:
    response = client.post("/api/capture")

    assert response.status_code == 422


def test_capture_upload_video_file() -> None:
    file = io.BytesIO(b"fake video data")
    response = client.post(
        "/api/capture",
        files={"file": ("clip.mp4", file, "video/mp4")},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["filename"] == "clip.mp4"
    assert payload["content_type"] == "video/mp4"


def test_capture_upload_includes_pipeline_fields() -> None:
    file = io.BytesIO(b"fake image data")
    response = client.post(
        "/api/capture",
        files={"file": ("test.jpg", file, "image/jpeg")},
    )

    payload = response.json()
    assert "total_frames" in payload
    assert "faces_detected" in payload
    assert "persons_created" in payload
    assert isinstance(payload["total_frames"], int)
    assert isinstance(payload["faces_detected"], int)
    assert isinstance(payload["persons_created"], list)
