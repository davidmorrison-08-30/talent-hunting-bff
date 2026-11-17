"""Tests for the BFF handler.

The upstream call is mocked so the suite runs offline.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
from pathlib import Path
from typing import Any
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture()
def bff(monkeypatch: pytest.MonkeyPatch) -> Any:
    """Import the handler with test environment variables applied."""
    monkeypatch.setenv("BACKEND_BASE_URL", "https://api.example.com")
    monkeypatch.setenv("FRONTEND_ORIGIN", "https://app.example.com")
    module = importlib.import_module("handler")
    importlib.reload(module)
    return module


def make_event(
    path: str = "/api/v1/health",
    method: str = "GET",
    body: Any = None,
    headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Build an API Gateway HTTP API (payload format 2.0) event."""
    raw_body = ""
    if body is not None:
        raw_body = json.dumps(body)
    return {
        "rawPath": path,
        "rawQueryString": "",
        "headers": headers or {},
        "body": raw_body or None,
        "isBase64Encoded": False,
        "requestContext": {
            "http": {"method": method, "path": path},
        },
    }


def make_rest_event(
    path: str = "/api/v1/health",
    method: str = "GET",
    body: Any = None,
    headers: dict[str, str] | None = None,
    stage: str = "default",
    query_params: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Build an API Gateway REST API (payload format 1.0) event."""
    raw_body = ""
    if body is not None:
        raw_body = json.dumps(body)
    event: dict[str, Any] = {
        "resource": "/{proxy+}",
        "path": f"/{stage}{path}",
        "httpMethod": method,
        "headers": headers or {},
        "body": raw_body or None,
        "isBase64Encoded": False,
        "requestContext": {
            "stage": stage,
            "path": f"/{stage}{path}",
            "httpMethod": method,
            "resourcePath": "/{proxy+}",
            "identity": {},
        },
    }
    if query_params:
        # A REST API puts the query in these top-level dictionaries, not in
        # the request context.
        event["queryStringParameters"] = dict(query_params)
        event["multiValueQueryStringParameters"] = {
            key: [value] for key, value in query_params.items()
        }
    return event


class FakeResponse:
    """Minimal stand-in for an urllib response object."""

    def __init__(self, status: int, payload: bytes, content_type: str = "application/json") -> None:
        self.status = status
        self._payload = payload
        self.headers = {"content-type": content_type}

    def read(self) -> bytes:
        return self._payload

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None


def test_options_returns_no_content(bff: Any) -> None:
    event = make_event(method="OPTIONS", headers={"origin": "https://app.example.com"})
    response = bff.handler(event, None)
    assert response["statusCode"] == 204
    assert response["headers"]["access-control-allow-origin"] == "https://app.example.com"


def test_disallowed_origin_gets_no_cors_header(bff: Any) -> None:
    event = make_event(headers={"origin": "https://evil.example.com"})
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")):
        response = bff.handler(event, None)
    assert "access-control-allow-origin" not in response["headers"]


def test_successful_proxy_passes_body_through(bff: Any) -> None:
    payload = json.dumps({"status": "ok"}).encode()
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, payload)) as mock_open:
        response = bff.handler(make_event(), None)

    assert response["statusCode"] == 200
    assert json.loads(response["body"]) == {"status": "ok"}
    assert mock_open.call_args[0][0].full_url == "https://api.example.com/api/v1/health"


def test_query_string_is_forwarded(bff: Any) -> None:
    event = make_event(path="/api/v1/discovery/accounts")
    event["rawQueryString"] = "limit=25"
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"[]")) as mock_open:
        bff.handler(event, None)
    assert mock_open.call_args[0][0].full_url.endswith("/api/v1/discovery/accounts?limit=25")


def test_discovery_requires_segment_or_seeds(bff: Any) -> None:
    event = make_event(path="/api/v1/discovery/search", method="POST", body={})
    response = bff.handler(event, None)
    assert response["statusCode"] == 422
    error = json.loads(response["body"])["error"]
    assert error["code"] == "validation_error"


def test_discovery_accepts_valid_body(bff: Any) -> None:
    event = make_event(
        path="/api/v1/discovery/search",
        method="POST",
        body={"target_segment": ["robotics engineer"], "seed_accounts": []},
    )
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")):
        response = bff.handler(event, None)
    assert response["statusCode"] == 200


def test_discovery_accepts_minimal_limits(bff: Any) -> None:
    """The cheapest limits that still satisfy the backend schema are allowed."""
    event = make_event(
        path="/api/v1/discovery/search",
        method="POST",
        body={
            "target_segment": ["robotics"],
            "seed_accounts": [],
            "max_accounts": 1,
            "max_candidates": 1,
            "max_posts_per_account": 0,
        },
    )
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")):
        response = bff.handler(event, None)
    assert response["statusCode"] == 200


def test_discovery_rejects_limits_below_the_minimum(bff: Any) -> None:
    """A zero candidate count would still cost a search call, so it is refused."""
    event = make_event(
        path="/api/v1/discovery/search",
        method="POST",
        body={"target_segment": ["robotics"], "max_candidates": 0},
    )
    with patch("urllib.request.urlopen") as mock_open:
        response = bff.handler(event, None)
    assert response["statusCode"] == 422
    assert "max_candidates" in json.loads(response["body"])["error"]["message"]
    mock_open.assert_not_called()


def test_discovery_rejects_limits_above_the_maximum(bff: Any) -> None:
    event = make_event(
        path="/api/v1/discovery/search",
        method="POST",
        body={"target_segment": ["robotics"], "max_accounts": 201},
    )
    response = bff.handler(event, None)
    assert response["statusCode"] == 422
    assert "max_accounts" in json.loads(response["body"])["error"]["message"]


def test_discovery_rejects_non_integer_limits(bff: Any) -> None:
    event = make_event(
        path="/api/v1/discovery/search",
        method="POST",
        body={"target_segment": ["robotics"], "max_posts_per_account": "10"},
    )
    response = bff.handler(event, None)
    assert response["statusCode"] == 422
    assert "max_posts_per_account" in json.loads(response["body"])["error"]["message"]


def test_discovery_rejects_boolean_limits(bff: Any) -> None:
    """Booleans are ints in Python but are not valid counts."""
    event = make_event(
        path="/api/v1/discovery/search",
        method="POST",
        body={"target_segment": ["robotics"], "max_accounts": True},
    )
    response = bff.handler(event, None)
    assert response["statusCode"] == 422


def test_draft_requires_x_user_id(bff: Any) -> None:
    event = make_event(path="/api/v1/outreach/drafts", method="POST", body={"goal": "hi"})
    response = bff.handler(event, None)
    assert response["statusCode"] == 422


def test_invalid_json_is_rejected(bff: Any) -> None:
    event = make_event(path="/api/v1/outreach/drafts", method="POST")
    event["body"] = "{not json"
    response = bff.handler(event, None)
    assert response["statusCode"] == 400
    assert json.loads(response["body"])["error"]["code"] == "invalid_json"


def test_backend_error_envelope_is_preserved(bff: Any) -> None:
    import urllib.error

    envelope = json.dumps(
        {"error": {"code": "duplicate_outreach", "message": "Already exists"}}
    ).encode()
    error = urllib.error.HTTPError(
        "https://api.example.com/x", 409, "Conflict", {}, None  # type: ignore[arg-type]
    )
    error.read = lambda: envelope  # type: ignore[method-assign]

    with patch("urllib.request.urlopen", side_effect=error):
        response = bff.handler(make_event(path="/api/v1/outreach/drafts", method="POST",
                                          body={"x_user_id": "1"}), None)

    assert response["statusCode"] == 409
    assert json.loads(response["body"])["error"]["code"] == "duplicate_outreach"


def test_backend_host_header_is_set(bff: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(bff, "BACKEND_HOST_HEADER", "api.talent-hunting.internal")
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")) as mock_open:
        bff.handler(make_event(), None)
    request = mock_open.call_args[0][0]
    assert request.get_header("Host") == "api.talent-hunting.internal"


def test_upstream_failure_returns_502(bff: Any) -> None:
    with patch("urllib.request.urlopen", side_effect=OSError("no route")):
        response = bff.handler(make_event(), None)
    assert response["statusCode"] == 502
    assert json.loads(response["body"])["error"]["code"] == "upstream_error"


def test_long_running_paths_wait_without_a_socket_timeout(bff: Any) -> None:
    """A slow inference must not be cut short by the BFF."""
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")) as mock_open:
        bff.handler(
            make_event(
                path="/api/v1/discovery/search",
                method="POST",
                body={"target_segment": ["robotics"], "max_candidates": 1},
            ),
            None,
        )
    assert mock_open.call_args.kwargs["timeout"] is None


def test_per_draft_paths_wait_without_a_socket_timeout(bff: Any) -> None:
    """Approving and denying a draft can both take a while."""
    for path in (
        "/api/v1/outreach/drafts/abc/approve",
        "/api/v1/outreach/drafts/abc/deny",
    ):
        with patch(
            "urllib.request.urlopen", return_value=FakeResponse(200, b"{}")
        ) as mock_open:
            bff.handler(make_event(path=path, method="POST"), None)
        assert mock_open.call_args.kwargs["timeout"] is None


def test_short_paths_keep_a_socket_timeout(bff: Any) -> None:
    """Everything else must not be able to hang the function."""
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")) as mock_open:
        bff.handler(make_event(path="/api/v1/discovery/accounts"), None)
    assert mock_open.call_args.kwargs["timeout"] == bff.DEFAULT_TIMEOUT_SECONDS


def test_there_is_no_timeout_error_path(bff: Any) -> None:
    """The timeout response and its log were removed."""
    assert not hasattr(bff, "UPSTREAM_TIMEOUT_SECONDS")
    assert "upstream_timeout" not in Path(bff.__file__).read_text()


def test_a_slow_upstream_is_not_answered_with_504(bff: Any) -> None:
    """A timing out socket on a long-running path surfaces as a 502, not a 504."""
    with patch("urllib.request.urlopen", side_effect=TimeoutError("timed out")):
        response = bff.handler(
            make_event(
                path="/api/v1/discovery/search",
                method="POST",
                body={"target_segment": ["robotics"], "max_candidates": 1},
            ),
            None,
        )
    assert response["statusCode"] == 502
    assert json.loads(response["body"])["error"]["code"] == "upstream_error"


def test_rest_api_event_paths_are_forwarded_without_the_stage(
    bff: Any,
) -> None:
    """A REST API event carries the stage in its path; it must be stripped."""
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")) as mock_open:
        bff.handler(make_rest_event(path="/health"), None)
    assert mock_open.call_args[0][0].full_url == "https://api.example.com/health"


def test_rest_api_event_method_is_read_from_the_request_context(bff: Any) -> None:
    event = make_rest_event(path="/api/v1/discovery/search", method="POST", body={})
    response = bff.handler(event, None)
    # The body is invalid, so the validation error proves the method and the
    # path were read correctly from the format 1.0 event.
    assert response["statusCode"] == 422


def test_rest_api_long_running_paths_wait_without_a_timeout(bff: Any) -> None:
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")) as mock_open:
        bff.handler(
            make_rest_event(
                path="/api/v1/discovery/search",
                method="POST",
                body={"target_segment": ["robotics"], "max_candidates": 1},
            ),
            None,
        )
    assert mock_open.call_args.kwargs["timeout"] is None
    assert mock_open.call_args[0][0].full_url == (
        "https://api.example.com/api/v1/discovery/search"
    )


def test_rest_api_query_string_is_forwarded(bff: Any) -> None:
    event = make_rest_event(
        path="/api/v1/discovery/accounts", query_params={"limit": "25"}
    )
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"[]")) as mock_open:
        bff.handler(event, None)
    assert mock_open.call_args[0][0].full_url.endswith(
        "/api/v1/discovery/accounts?limit=25"
    )


def test_oauth_callback_query_is_forwarded(bff: Any) -> None:
    """The callback's code and state must reach the backend.

    X redirects to the callback with the authorization code in the query
    string. A REST API puts it in the top-level query parameter dictionaries,
    so dropping it would leave the backend without a code to exchange.
    """
    event = make_rest_event(
        path="/auth/x/callback",
        query_params={"code": "abc123", "state": "xyz789"},
    )
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")) as mock_open:
        bff.handler(event, None)
    assert mock_open.call_args[0][0].full_url == (
        "https://api.example.com/auth/x/callback?code=abc123&state=xyz789"
    )


def test_oauth_callback_query_values_are_encoded(bff: Any) -> None:
    """A state value with URL-significant characters must survive."""
    event = make_rest_event(
        path="/auth/x/callback",
        query_params={"code": "a+b/c=", "state": "s t&x"},
    )
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"{}")) as mock_open:
        bff.handler(event, None)
    url = mock_open.call_args[0][0].full_url
    assert url.startswith("https://api.example.com/auth/x/callback?")
    parsed = parse_qs(urlparse(url).query)
    assert parsed["code"] == ["a+b/c="]
    assert parsed["state"] == ["s t&x"]


def test_http_api_query_string_is_still_forwarded(bff: Any) -> None:
    """The format 2.0 behaviour must not change."""
    event = make_event(path="/api/v1/discovery/accounts")
    event["rawQueryString"] = "limit=25"
    with patch("urllib.request.urlopen", return_value=FakeResponse(200, b"[]")) as mock_open:
        bff.handler(event, None)
    assert mock_open.call_args[0][0].full_url.endswith(
        "/api/v1/discovery/accounts?limit=25"
    )
