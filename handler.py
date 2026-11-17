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

#: How long the backend may take before the BFF gives up, in seconds.
#: This must stay below the API Gateway HTTP API integration cap (30s) so the
#: function can return a real error response instead of being killed mid-flight
#: and surfacing an opaque 503 to the caller.
UPSTREAM_TIMEOUT_SECONDS = float(os.environ.get("UPSTREAM_TIMEOUT_SECONDS", "25"))

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


def _build_upstream_url(event: dict[str, Any]) -> str:
    """Rebuild the backend URL from the API Gateway event."""
    raw_path = event.get("rawPath") or "/"
    query = event.get("rawQueryString") or ""
    url = f"{BACKEND_BASE_URL}{raw_path}"
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
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path = event.get("rawPath") or "/"
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

    try:
        import urllib.error
        import urllib.request

        data = raw_body.encode("utf-8") if raw_body else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=UPSTREAM_TIMEOUT_SECONDS) as upstream:
            status = upstream.status
            payload = upstream.read()
            content_type = upstream.headers.get("content-type", "application/json")
    except urllib.error.HTTPError as exc:
        # The backend returned an error: pass its envelope through unchanged.
        status = exc.code
        payload = exc.read()
        content_type = exc.headers.get("content-type", "application/json")
    except TimeoutError:
        # The backend took longer than the upstream budget. API Gateway kills
        # the integration at 30s, so the BFF must answer first with a clear
        # error instead of being terminated and surfacing an opaque 503.
        _log(
            "error",
            "upstream_timeout",
            path=path,
            method=method,
            timeout_seconds=UPSTREAM_TIMEOUT_SECONDS,
        )
        response = _error_response(
            504,
            "upstream_timeout",
            "The backend did not respond in time. The operation may still "
            "have completed; check the run or record list before retrying.",
        )
        response["headers"].update(cors_headers)
        return response
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
