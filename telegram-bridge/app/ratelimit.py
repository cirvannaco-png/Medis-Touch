import asyncio
import time

from fastapi import HTTPException, Request

from app.config import settings


class InMemoryRateLimiter:
    """
    Simple fixed-window rate limiter, keyed per client.

    Note: state is per-process. If this service ever runs with multiple
    uvicorn workers or multiple instances behind a load balancer, each
    process enforces its own independent limit rather than a shared global
    one. For a single-instance Render deployment this is fine; if you scale
    out, move this to Redis (INCR + EXPIRE) instead.
    """

    def __init__(self, max_requests: int, window_seconds: int, enabled: bool = True):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self.enabled = enabled
        self._buckets: dict[str, tuple[int, float]] = {}
        self._lock = asyncio.Lock()

    async def allow(self, key: str) -> bool:
        if not self.enabled:
            return True
        now = time.time()
        async with self._lock:
            count, window_start = self._buckets.get(key, (0, now))
            if now - window_start >= self.window_seconds:
                count = 0
                window_start = now
            count += 1
            self._buckets[key] = (count, window_start)
            return count <= self.max_requests


rate_limiter = InMemoryRateLimiter(
    max_requests=settings.RATE_LIMIT_MAX_REQUESTS,
    window_seconds=settings.RATE_LIMIT_WINDOW_SECONDS,
    enabled=settings.RATE_LIMIT_ENABLED,
)


def get_client_key(request: Request) -> str:
    """
    Proxy-aware client identification. Render (and most PaaS load balancers)
    terminate TLS in front of the app, so request.client.host alone is the
    proxy's IP for every request - that either rate-limits everyone as one
    bucket or defeats limiting entirely. Prefer the first X-Forwarded-For hop.
    """
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    if request.client:
        return request.client.host
    return "unknown"


async def enforce_rate_limit(request: Request) -> None:
    key = get_client_key(request)
    allowed = await rate_limiter.allow(key)
    if not allowed:
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
