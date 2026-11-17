# talent-hunting-bff

The backend-for-frontend that sits between the browser and the FastAPI backend.

It runs as a single Lambda function (`talent-hunting-bff`) behind an API Gateway
REST API, and forwards each request to the backend ECS service on the shared
ALB. Its job is to keep the browser's origin rules in one place, so the
backend never has to be exposed directly.

## How a request flows

```
Browser -> CloudFront (/api/*) -> API Gateway -> Lambda -> ALB -> ECS backend
```

The Lambda sets the `Host` header to `api.talent-hunting.internal` so the ALB
routes the request to the backend target group.

## Long-running requests

Some backend calls wait on an LLM inference and can take much longer than a
normal request. Those endpoints are forwarded without a socket timeout, so the
browser and the gateway simply wait for the inference to finish:

- `POST /api/v1/discovery/search`
- `POST /api/v1/outreach/drafts`
- `POST /api/v1/outreach/drafts/{id}/approve`
- `POST /api/v1/outreach/drafts/{id}/deny`

Every other endpoint keeps a 25 second timeout, so a broken backend cannot
hang the function.

## Configuration

The function reads these environment variables:

| Variable | Purpose |
| --- | --- |
| `BACKEND_BASE_URL` | Base URL of the backend behind the shared ALB. |
| `BACKEND_HOST_HEADER` | Host header the ALB routes on. |
| `FRONTEND_ORIGIN` | Comma-separated list of allowed browser origins. |

## Development

```bash
uv run --with pytest python -m pytest tests/ -q
```

The handler has no third-party dependencies, so the deployment package is just
this directory.

## Deploying

Pushing to `main` runs `.github/workflows/deploy-bff.yml`, which tests the
handler and then runs `deploy.sh`. The AWS role is assumed through keyless
OIDC, so no GitHub secret is needed.

```bash
./deploy.sh <backend-base-url> <frontend-origin>
```

The script creates a REST API (API Gateway v1) with a `{proxy+}` resource, so
every path is forwarded to the function. The public URL is derived from the
REST API id and printed at the end of the run.

## Layout

- `handler.py` - the Lambda entry point and request forwarding.
- `config.py` - the environment variables the function reads.
- `deploy.sh` - packages and deploys the function.
- `infra/` - one-off setup scripts for the ALB, ECS and CloudFront.
- `tests/` - the handler tests that run as the CI quality gate.
