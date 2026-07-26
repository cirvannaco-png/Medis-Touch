from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import declarative_base

from app.config import settings

engine = create_async_engine(settings.DATABASE_URL, echo=False, future=True)
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
Base = declarative_base()


async def init_db():
    """
    Dev/test convenience only: creates tables directly from the models if
    they don't already exist (harmless no-op against a DB that's already
    up to date). In production the schema is owned by Alembic migrations
    (see migrations/) - this call does not replace `alembic upgrade head`
    and won't apply schema changes to an existing table.
    """
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def check_db_connection() -> bool:
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


async def get_session() -> AsyncSession:
    async with async_session() as session:
        yield session
