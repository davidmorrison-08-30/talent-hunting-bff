# talent-hunting-bff

The backend-for-frontend that sits between the browser and the FastAPI backend.

It runs as a single Lambda function (`talent-hunting-bff`) behind an API Gateway
HTTP API, and forwards each request to the backend ECS service on the shared
ALB. Its job is to keep the browser's origin rules in one place, so the
backend never has to be exposed directly.

## How a request flows

```
Browser -> CloudFront (/api/*) -> API Gateway -> Lambda -> ALB -> ECS backend
```

The Lambda sets the `Host` header to `api.talent-hunting.internal` so the ALB
routes the request to the backend target group.

## Configuration

The function reads these environment variables:

| Variable | Purpose |
| --- | --- |
| `BACKEND_BASE_URL` | Base URL of the backend behind the shared ALB. |
| `BACKEND_HOST_HEADER` | Host header the ALB routes on. |
| `FRONTEND_ORIGIN` | Comma-separated list of allowed browser origins. |
| `UPSTREAM_TIMEOUT_SECONDS` | How long to wait for the backend, in seconds. |

The upstream timeout is deliberately shorter than the Lambda timeout. The
Lambda timeout is set below the 30 second ceiling of an API Gateway HTTP API
integration, so an upstream that hangs produces a structured `504` with
`upstream_timeout` rather than an opaque gateway error.

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
./deploy.sh <api-gateway-url> <backend-base-url> <frontend-origin>
```

## Layout

- `handler.py` - the Lambda entry point and request forwarding.
- `config.py` - the environment variables the function reads.
- `deploy.sh` - packages and deploys the function.
- `infra/` - one-off setup scripts for the ALB, ECS and CloudFront.
- `tests/` - the handler tests that run as the CI quality gate.
