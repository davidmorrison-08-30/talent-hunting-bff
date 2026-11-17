"""Talent Hunting BFF.

A thin intermediary between the browser and the FastAPI backend.

Responsibilities:
  * terminate the browser request at API Gateway and apply CORS,
  * validate the shape of the requests that need it,
  * forward the call to the backend behind the shared ALB,
  * keep the backend's structured error envelope intact,
  * emit structured JSON logs to CloudWatch.

It deliberately holds no business logic and no credentials: the backend stays
the single source of truth for the compliance rules.

Endpoints whose upstream work waits on an LLM inference are forwarded without
a socket timeout, so the caller simply waits for the inference to finish.
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

#: Backend base URL (the ALB host that routes to the backend target group).
BACKEND_BASE_URL = os.environ.get("BACKEND_BASE_URL", "http://localhost:8000").rstrip("/")

#: Host header sent to the backend. The shared ALB routes on the host
#: header, so this must be the routing label that points at the backend
#: target group (not the ALB's own DNS name).
BACKEND_HOST_HEADER = os.environ.get("BACKEND_HOST_HEADER", "")

#: Origins allowed to call the API. Comma separated.
ALLOWED_ORIGINS = [
    origin.strip()
    for origin in os.environ.get("FRONTEND_ORIGIN", "").split(",")
    if origin.strip()
]

#: Paths whose upstream call may run for a long time because the backend
#: waits on LLM inference. These are forwarded without a socket timeout, so
#: the caller simply waits for the inference to finish.
LONG_RUNNING_PATHS = {
    "/api/v1/discovery/search",
    "/api/v1/outreach/drafts",
}

#: Prefix match for the per-draft endpoints. Approving a draft re-checks the
#: guards and sending it is paced, and denying one regenerates the draft with
#: the LLM, so both can be slow.
LONG_RUNNING_PREFIXES = (
    "/api/v1/outreach/drafts/",
)

#: The timeout applied to every other upstream call, in seconds. These
#: endpoints only read from the database or the X API, so they either answer
#: quickly or are genuinely broken.
DEFAULT_TIMEOUT_SECONDS = 25

#: Paths that are forwarded without a body validation pass.
VALIDATED_POST_PATHS = {
    "/api/v1/discovery/search",
    "/api/v1/outreach/drafts",
}

#: The discovery limits that decide how much of the X API budget one run
#: may spend: field name -> (minimum, maximum). The bounds mirror the
#: FastAPI schema so a value that would be rejected downstream is caught
#: here, before any paid X request is made.
DISCOVERY_LIMIT_FIELDS: tuple[tuple[str, int, int], ...] = (
    ("max_accounts", 1, 200),
    ("max_candidates", 1, 500),
    ("max_posts_per_account", 0, 100),
)

#: The values the backend uses when a limit is not supplied.
DEFAULT_DISCOVERY_LIMITS: dict[str, int] = {
    "max_accounts": 40,
    "max_candidates": 150,
    "max_posts_per_account": 20,
}

#: Maximum request body size the BFF will forward, in bytes.
MAX_BODY_BYTES = 1_048_576


def _log(level: str, message: str, **fields: Any) -> None:
    """Emit one structured JSON log line."""
    payload = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "level": level.upper(),
        "message": message,
        **fields,
    }
    print(json.dumps(payload, default=str))


def _cors_origin(event: dict[str, Any]) -> str | None:
    """Return the allowed origin for this request, if any."""
    headers = event.get("headers") or {}
    origin = headers.get("origin") or headers.get("Origin")
    if not origin:
        return None
    if "*" in ALLOWED_ORIGINS:
        return "*"
    if origin in ALLOWED_ORIGINS:
        return origin
    return None


def _error_response(status: int, code: str, message: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    """Build the same error envelope the backend uses."""
    body: dict[str, Any] = {"error": {"code": code, "message": message}}
    if extra:
        body["error"]["details"] = extra
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
        "isBase64Encoded": False,
    }


def _validate_body(path: str, body: Any) -> str | None:
    """Return an error message when the body is not acceptable."""
    if path not in VALIDATED_POST_PATHS:
        return None
    if not isinstance(body, dict):
        return "Request body must be a JSON object"

    if path == "/api/v1/discovery/search":
        segment = body.get("target_segment") or []
        seeds = body.get("seed_accounts") or []
        if not isinstance(segment, list) or not isinstance(seeds, list):
            return "'target_segment' and 'seed_accounts' must be lists"
        if not segment and not seeds:
            return "Provide at least one of 'target_segment' or 'seed_accounts'"
        for field, low, high in DISCOVERY_LIMIT_FIELDS:
            value = body.get(field, DEFAULT_DISCOVERY_LIMITS[field])
            if not isinstance(value, int) or isinstance(value, bool):
                return f"'{field}' must be an integer"
            if not low <= value <= high:
                return f"'{field}' must be between {low} and {high}"

    if path == "/api/v1/outreach/drafts":
        x_user_id = body.get("x_user_id")
        if not isinstance(x_user_id, str) or not x_user_id.strip():
            return "'x_user_id' is required"

    return None


def _is_long_running(path: str) -> bool:
    """Return whether the path may wait for an LLM inference to finish."""
    if path in LONG_RUNNING_PATHS:
        return True
    return any(path.startswith(prefix) for prefix in LONG_RUNNING_PREFIXES)


def _event_path(event: dict[str, Any]) -> str:
    """Return the request path, whichever API Gateway payload format is used.

    A REST API sends payload format 1.0, which has no "rawPath" and instead
    puts the path in the request context. A HTTP API sends format 2.0, which
    has "rawPath".
    """
    raw_path = event.get("rawPath")
    if raw_path:
        return raw_path

    request_context = event.get("requestContext") or {}
    # Format 1.0: requestContext.path holds "/stage/resource/path".
    path = request_context.get("path")
    if path:
        stage = request_context.get("stage")
        if stage and stage != "$default":
            prefix = f"/{stage}"
            if path.startswith(prefix):
                path = path[len(prefix) :] or "/"
        return path

    # Format 2.0: requestContext.http.path holds the path without the stage.
    http_context = request_context.get("http") or {}
    return http_context.get("path") or "/"


def _event_query(event: dict[str, Any]) -> str:
    """Return the raw query string, whichever payload format is used."""
    query = event.get("rawQueryString")
    if query:
        return query

    request_context = event.get("requestContext") or {}
    http_context = request_context.get("http") or {}
    if http_context.get("queryString"):
        return http_context["queryString"]

    # Format 1.0 puts the query string in the request context.
    for key in ("queryString", "query"):
        value = request_context.get(key)
        if value:
            return value
    return ""


def _event_method(event: dict[str, Any]) -> str:
    """Return the HTTP method, whichever payload format is used."""
    request_context = event.get("requestContext") or {}
    http_context = request_context.get("http") or {}
    method = http_context.get("method") or request_context.get("httpMethod")
    return method or "GET"


def _build_upstream_url(event: dict[str, Any]) -> str:
    """Rebuild the backend URL from the API Gateway event."""
    url = f"{BACKEND_BASE_URL}{_event_path(event)}"
    query = _event_query(event)
    if query:
        url = f"{url}?{query}"
    return url


def _forwardable_headers(event: dict[str, Any]) -> dict[str, str]:
    """Copy through the headers the backend cares about."""
    headers = event.get("headers") or {}
    keep = ("content-type", "accept", "authorization", "user-agent", "x-request-id")
    forwarded = {key: value for key, value in headers.items() if key.lower() in keep}
    if BACKEND_HOST_HEADER:
        # The shared ALB selects the backend target group by host header.
        forwarded["Host"] = BACKEND_HOST_HEADER
    return forwarded


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Proxy an API Gateway request to the backend."""
    method = _event_method(event)
    path = _event_path(event)
    started = time.perf_counter()

    cors = _cors_origin(event)
    cors_headers: dict[str, str] = {}
    if cors:
        cors_headers = {
            "access-control-allow-origin": cors,
            "access-control-allow-headers": "content-type,authorization",
            "access-control-allow-methods": "GET,POST,OPTIONS,DELETE,PATCH",
            "vary": "Origin",
        }

    if method == "OPTIONS":
        return {
            "statusCode": 204,
            "headers": cors_headers,
            "body": "",
            "isBase64Encoded": False,
        }

    # Parse and validate the body.
    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded") and raw_body:
        import base64

        raw_body = base64.b64decode(raw_body).decode("utf-8", errors="replace")

    if len(raw_body.encode("utf-8")) > MAX_BODY_BYTES:
        response = _error_response(413, "payload_too_large", "Request body is too large")
        response["headers"].update(cors_headers)
        return response

    parsed_body: Any = None
    if raw_body:
        try:
            parsed_body = json.loads(raw_body)
        except json.JSONDecodeError as exc:
            response = _error_response(400, "invalid_json", f"Body is not valid JSON: {exc}")
            response["headers"].update(cors_headers)
            return response

    validation_error = _validate_body(path, parsed_body)
    if validation_error:
        response = _error_response(422, "validation_error", validation_error)
        response["headers"].update(cors_headers)
        return response

    url = _build_upstream_url(event)
    headers = _forwardable_headers(event)
    # The long-running endpoints wait for the backend without a socket
    # timeout, so a slow inference is never cut short by the BFF.
    timeout = None if _is_long_running(path) else DEFAULT_TIMEOUT_SECONDS

    try:
        import urllib.error
        import urllib.request

        data = raw_body.encode("utf-8") if raw_body else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=timeout) as upstream:
            status = upstream.status
            payload = upstream.read()
            content_type = upstream.headers.get("content-type", "application/json")
    except urllib.error.HTTPError as exc:
        # The backend returned an error: pass its envelope through unchanged.
        status = exc.code
        payload = exc.read()
        content_type = exc.headers.get("content-type", "application/json")
    except Exception as exc:  # noqa: BLE001
        _log("error", "upstream_request_failed", path=path, method=method, error=str(exc))
        response = _error_response(502, "upstream_error", "The backend could not be reached")
        response["headers"].update(cors_headers)
        return response

    duration_ms = round((time.perf_counter() - started) * 1000, 2)
    _log("info", "proxied", path=path, method=method, status=status, duration_ms=duration_ms)

    response_headers = {"content-type": content_type}
    response_headers.update(cors_headers)
    return {
        "statusCode": status,
        "headers": response_headers,
        "body": payload.decode("utf-8", errors="replace"),
        "isBase64Encoded": False,
    }
