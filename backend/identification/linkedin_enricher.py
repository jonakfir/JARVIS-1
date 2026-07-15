from __future__ import annotations

import re
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urlsplit

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


def _parse_profile(html: str) -> tuple[str, LinkedInRole] | None:
    parser = _TitleMetadataParser()
    parser.feed(html)
    title = parser.open_graph_title or parser.document_title
    if not title:
        return None

    normalized = re.sub(r"\s*\|\s*LinkedIn\s*$", "", title, flags=re.IGNORECASE).strip()
    if " - " not in normalized:
        return None
    profile_name, role_and_company = normalized.split(" - ", maxsplit=1)
    match = re.fullmatch(r"(?P<role>.+?)\s+at\s+(?P<company>.+)", role_and_company)
    if match is None:
        return None

    job_title = match.group("role").strip()
    company = match.group("company").strip()
    profile_name = profile_name.strip()
    if not profile_name or not job_title or not company:
        return None
    return profile_name, LinkedInRole(job_title=job_title, company=company)


def parse_role(html: str) -> LinkedInRole | None:
    """Parse a current role only from unambiguous LinkedIn title metadata."""
    profile = _parse_profile(html)
    return profile[1] if profile is not None else None


class LinkedInEnricher:
    """Best-effort role lookup for a direct LinkedIn profile evidence URL."""

    def __init__(self, client: httpx.AsyncClient | None = None) -> None:
        self._client = client

    @staticmethod
    def is_allowed_profile_url(profile_url: str) -> bool:
        try:
            parsed = urlsplit(profile_url)
            port = parsed.port
        except ValueError:
            return False
        if (
            parsed.scheme != "https"
            or parsed.hostname not in {"linkedin.com", "www.linkedin.com"}
            or parsed.username is not None
            or parsed.password is not None
            or port is not None
            or bool(parsed.query)
            or bool(parsed.fragment)
        ):
            return False
        return re.fullmatch(r"/in/[A-Za-z0-9_-]+/?", parsed.path) is not None

    @staticmethod
    def _canonical_profile_url(profile_url: str) -> str | None:
        if not LinkedInEnricher.is_allowed_profile_url(profile_url):
            return None
        parsed = urlsplit(profile_url)
        slug = parsed.path.rstrip("/").removeprefix("/in/").casefold()
        return f"https://linkedin.com/in/{slug}"

    async def enrich(
        self,
        profile_url: str,
        *,
        expected_name: str,
    ) -> LinkedInRole | None:
        supplied_canonical_url = self._canonical_profile_url(profile_url)
        if supplied_canonical_url is None:
            return None

        try:
            if self._client is not None:
                response = await self._client.get(profile_url)
            else:
                async with httpx.AsyncClient(follow_redirects=False, timeout=10.0) as client:
                    response = await client.get(profile_url)
            if 300 <= response.status_code < 400:
                logger.info("Direct LinkedIn profile returned a redirect; rejecting")
                return None
            response.raise_for_status()
            if self._canonical_profile_url(str(response.url)) != supplied_canonical_url:
                logger.info("LinkedIn response URL did not match supplied profile evidence")
                return None
            profile = _parse_profile(response.text)
            if profile is None:
                return None
            profile_name, role = profile
            if profile_name.strip().casefold() != expected_name.strip().casefold():
                logger.info("LinkedIn profile name did not match resolved face-search name")
                return None
            return role
        except (httpx.HTTPError, ValueError) as exc:
            logger.info("Direct LinkedIn enrichment unavailable: {}", exc)
            return None
