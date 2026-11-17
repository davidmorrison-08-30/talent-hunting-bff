"""BFF configuration and packaging for AWS Lambda.

The handler is a single file with no third-party dependencies, so the Lambda
deployment package is just this directory.
"""

from __future__ import annotations

#: Environment variables the function reads at cold start.
ENVIRONMENT_VARIABLES = {
    "BACKEND_BASE_URL": "Base URL of the backend behind the shared ALB.",
    "FRONTEND_ORIGIN": "Comma-separated list of allowed browser origins.",
    "UPSTREAM_TIMEOUT_SECONDS": "How long to wait for the backend, in seconds.",
}
