from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest

from identification.linkedin_enricher import LinkedInEnricher, LinkedInRole, parse_role
from identification.models import FaceSearchMatch, FaceSearchResult
from identification.search_manager import FaceSearchManager


@pytest.mark.parametrize(
    ("url", "allowed"),
    [
        ("https://www.linkedin.com/in/jane-doe", True),
        ("https://linkedin.com/in/jane-doe/", True),
        ("http://www.linkedin.com/in/jane-doe", False),
        ("https://www.linkedin.com/search/results/people/?keywords=Jane", False),
        ("https://example.com/in/jane-doe", False),
        ("https://linkedin.com.evil.example/in/jane-doe", False),
        ("https://www.linkedin.com/in/", False),
    ],
)
def test_allowed_profile_url_policy(url: str, allowed: bool) -> None:
    assert LinkedInEnricher.is_allowed_profile_url(url) is allowed


def test_parse_role_from_open_graph_title() -> None:
    html = '<meta property="og:title" content="Jane Doe - Engineer at Acme | LinkedIn">'

    assert parse_role(html) == LinkedInRole(job_title="Engineer", company="Acme")


@pytest.mark.parametrize(
    "html",
    [
        "<html><title>Jane Doe | LinkedIn</title></html>",
        '<meta property="og:title" content="Jane Doe - LinkedIn">',
        '<meta property="og:title" content="Sign In | LinkedIn">',
        '<meta property="og:title" content="Jane Doe - Engineer">',
        "<html></html>",
    ],
)
def test_parse_role_rejects_missing_or_ambiguous_metadata(html: str) -> None:
    assert parse_role(html) is None


@pytest.mark.asyncio
async def test_enrich_fetches_only_the_supplied_direct_profile_url() -> None:
    profile_url = "https://www.linkedin.com/in/jane-doe"
    response = MagicMock(spec=httpx.Response)
    response.text = (
        '<meta property="og:title" content="Jane Doe - Engineer at Acme | LinkedIn">'
    )
    response.url = httpx.URL(profile_url)
    response.raise_for_status.return_value = None
    client = MagicMock(spec=httpx.AsyncClient)
    client.get = AsyncMock(return_value=response)
    enricher = LinkedInEnricher(client=client)

    role = await enricher.enrich(profile_url)

    assert role == LinkedInRole(job_title="Engineer", company="Acme")
    client.get.assert_awaited_once_with(profile_url)


@pytest.mark.asyncio
async def test_enrich_rejects_non_profile_url_without_network_request() -> None:
    client = MagicMock(spec=httpx.AsyncClient)
    client.get = AsyncMock()
    enricher = LinkedInEnricher(client=client)

    assert await enricher.enrich("https://linkedin.com/search/results/people") is None
    client.get.assert_not_awaited()


def test_profile_evidence_must_match_the_resolved_name() -> None:
    manager = FaceSearchManager.__new__(FaceSearchManager)
    result = FaceSearchResult(
        matches=[
            FaceSearchMatch(
                url="https://www.linkedin.com/in/jane-doe",
                similarity=0.95,
                source="pimeyes",
                person_name="Jane Doe",
            ),
            FaceSearchMatch(
                url="https://www.linkedin.com/in/john-doe",
                similarity=0.90,
                source="pimeyes",
                person_name="John Doe",
            ),
            FaceSearchMatch(
                url="https://www.linkedin.com/in/unknown",
                similarity=0.85,
                source="pimeyes",
            ),
        ],
    )

    assert manager.profile_urls_from_results(result, person_name="Jane Doe") == [
        "https://www.linkedin.com/in/jane-doe",
    ]
