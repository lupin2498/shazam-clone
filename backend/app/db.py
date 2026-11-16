from __future__ import annotations

from typing import Any

from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine

from .models import Base


async def insert_if_absent(session: AsyncSession, model: type[Base], values: dict[str, Any],
                           conflict_columns: list[str]) -> bool:
    """``INSERT ... ON CONFLICT DO NOTHING``. Returns whether this call inserted the row.

    Two requests may try to store the same track or link at the same moment. A plain
    SELECT-then-INSERT lets the second one hit the unique constraint, which aborts its
    transaction (a 500, or an SSE stream cut half-way). Here the loser simply finds the
    winner's row afterwards.
    """
    dialect = session.bind.dialect.name
    insert = pg_insert if dialect == "postgresql" else sqlite_insert
    stmt = insert(model).values(**values).on_conflict_do_nothing(index_elements=conflict_columns)
    result = await session.execute(stmt)
    return result.rowcount == 1


class Database:
    def __init__(self, url: str) -> None:
        kwargs: dict = {}
        if not url.startswith("sqlite"):
            kwargs.update(pool_pre_ping=True, pool_size=10, max_overflow=20)
        self.engine: AsyncEngine = create_async_engine(url, **kwargs)
        self.sessionmaker: async_sessionmaker[AsyncSession] = async_sessionmaker(
            self.engine, expire_on_commit=False
        )

    async def create_all(self) -> None:
        async with self.engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)

    async def dispose(self) -> None:
        await self.engine.dispose()
