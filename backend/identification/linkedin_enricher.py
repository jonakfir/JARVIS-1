from __future__ import annotations

import re
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urlparse

import httpx
from loguru import logger


@dataclass(frozen=True, slots=True)
class LinkedInRole:
    job_title: str
    company: str | None = None


class _TitleMetadataParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.open_graph_title: str | None = None
        self.title_parts: list[str] = []
        self._in_title = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {key.lower(): value for key, value in attrs}
        if tag.lower() == "meta" and attributes.get("property", "").lower() == "og:title":
            self.open_graph_title = attributes.get("content")
        elif tag.lower() == "title":
            self._in_title = True

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self._in_title = False

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title_parts.append(data)

    @property
    def document_title(self) -> str | None:
        title = "".join(self.title_parts).strip()
        return title or None


def parse_role(html: str) -> LinkedInRole | None:
    """Parse a current role only from unambiguous LinkedIn title metadata."""
    parser = _TitleMetadataParser()
    parser.feed(html)
    title = parser.open_graph_title or parser.document_title
    if not title:
        return None

    normalized = re.sub(r"\s*\|\s*LinkedIn\s*$", "", title, flags=re.IGNORECASE).strip()
    if " - " not in normalized:
        return None
    _, role_and_company = normalized.split(" - ", maxsplit=1)
    match = re.fullmatch(r"(?P<role>.+?)\s+at\s+(?P<company>.+)", role_and_company)
    if match is None:
        return None

    job_title = match.group("role").strip()
    company = match.group("company").strip()
    if not job_title or not company:
        return None
    return LinkedInRole(job_title=job_title, company=company)


class LinkedInEnricher:
    """Best-effort role lookup for a direct LinkedIn profile evidence URL."""

    def __init__(self, client: httpx.AsyncClient | None = None) -> None:
        self._client = client

    @staticmethod
    def is_allowed_profile_url(profile_url: str) -> bool:
        try:
            parsed = urlparse(profile_url)
        except ValueError:
            return False
        if parsed.scheme != "https" or parsed.hostname not in {"linkedin.com", "www.linkedin.com"}:
            return False
        path_parts = [part for part in parsed.path.split("/") if part]
        return len(path_parts) >= 2 and path_parts[0] == "in" and bool(path_parts[1])

    async def enrich(self, profile_url: str) -> LinkedInRole | None:
        if not self.is_allowed_profile_url(profile_url):
            return None

        try:
            if self._client is not None:
                response = await self._client.get(profile_url)
            else:
                async with httpx.AsyncClient(follow_redirects=True, timeout=10.0) as client:
                    response = await client.get(profile_url)
            response.raise_for_status()
            if not self.is_allowed_profile_url(str(response.url)):
                logger.info("LinkedIn profile redirected outside the allowed profile path")
                return None
            return parse_role(response.text)
        except (httpx.HTTPError, ValueError) as exc:
            logger.info("Direct LinkedIn enrichment unavailable: {}", exc)
            return None
