from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


class ApiError(Exception):
    """Error with a stable machine code and a Vietnamese message the app can show as-is."""

    def __init__(self, status: int, code: str, message: str, *, detail: str | None = None,
                 headers: dict[str, str] | None = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.detail = detail
        self.headers = headers


def install_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
        body = {"error": exc.code, "message": exc.message}
        if exc.detail:
            body["detail"] = exc.detail
        return JSONResponse(body, status_code=exc.status, headers=exc.headers)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            {"error": "invalid_request", "message": "Yêu cầu không hợp lệ.", "detail": str(exc.errors())[:500]},
            status_code=422,
        )
