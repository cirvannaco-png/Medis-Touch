from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import JSONResponse, Response

from app.config import APP_VERSION, settings
from app.database import init_db
from app.logger import logger
from app.routes import router
from app.telegram import check_bot_token, close_http_client, init_http_client


class RequestBodyTooLarge(Exception):
    pass


class MaxBodySizeMiddleware:
    """
    Raw ASGI middleware. Rejects on Content-Length first (cheap, catches the
    common case), and also enforces the limit against the actual bytes
    streamed in - a Content-Length header is caller-supplied and can be
    absent (chunked transfer) or simply wrong, so it can't be trusted alone.
    """

    def __init__(self, app, max_size: int):
        self.app = app
        self.max_size = max_size

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        for key, value in scope.get("headers", []):
            if key == b"content-length":
                try:
                    if int(value) > self.max_size:
                        response = Response(
                            content='{"detail":"Request body too large"}',
                            status_code=413,
                            media_type="application/json",
                        )
                        await response(scope, receive, send)
                        return
                except ValueError:
                    pass
                break

        total = 0

        async def limited_receive():
            nonlocal total
            message = await receive()
            if message["type"] == "http.request":
                total += len(message.get("body", b""))
                if total > self.max_size:
                    raise RequestBodyTooLarge()
            return message

        await self.app(scope, limited_receive, send)


def create_app() -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        logger.info("Starting application...")
        await init_http_client()
        await init_db()
        logger.info("Database initialized.")
        token_valid = await check_bot_token()
        if not token_valid:
            logger.warning("Telegram bot token is invalid or could not be verified. Signals will fail.")
        yield
        await close_http_client()
        logger.info("Shutdown complete.")

    app = FastAPI(title="Medis Touch Telegram Bridge", version=APP_VERSION, lifespan=lifespan)

    # CORS is only relevant for browser clients; the EA talks to this API
    # directly and isn't subject to it. Wildcard origins + credentials is an
    # invalid combination (rejected by browsers per spec) and was never
    # actually enforceable as written before - if you need a browser
    # dashboard hitting this API, set ALLOWED_ORIGINS to explicit origins.
    allowed_origins = settings.allowed_origins_list
    if allowed_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=allowed_origins,
            allow_credentials=True,
            allow_methods=["POST", "GET"],
            allow_headers=["X-API-Key", "Content-Type"],
        )

    app.add_middleware(MaxBodySizeMiddleware, max_size=settings.MAX_REQUEST_BODY_SIZE)

    @app.exception_handler(RequestBodyTooLarge)
    async def body_too_large_handler(request, exc):
        return JSONResponse(status_code=413, content={"detail": "Request body too large"})

    app.include_router(router)

    return app


app = create_app()
