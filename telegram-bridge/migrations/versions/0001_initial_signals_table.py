"""initial signals table

    Revision ID: 0001
    Revises:
    Create Date: 2026-07-26

    This captures the schema previously created implicitly by
    Base.metadata.create_all() at app startup. From this point on, schema
    changes go through a new revision instead of relying on create_all(),
    which has no upgrade/rollback path once there's real data to protect.
    """
    from alembic import op
    import sqlalchemy as sa

    revision = "0001"
    down_revision = None
    branch_labels = None
    depends_on = None

    # create_type=False: we manage the enum lifecycle explicitly below so that
    # op.create_table() does NOT emit a second CREATE TYPE statement for the
    # status column.  Without this, SQLAlchemy emits CREATE TYPE twice — once
    # from our explicit call and once internally — and the second attempt fails
    # even when checkfirst=True is used, because asyncpg surfaces the duplicate
    # inside the same transaction before the check can run.
    signal_status_enum = sa.Enum(
      "pending", "active", "failed", "permanently_failed", "duplicate",
      name="signalstatus",
      create_type=False,
    )


    def upgrade() -> None:
      # Use PostgreSQL's native exception-handler instead of SQLAlchemy's
      # checkfirst=True.  Under asyncpg + SQLAlchemy 2.x the ORM-level check
      # queries pg_catalog.pg_type inside the same transaction that holds the
      # write lock, which can cause the check to see a stale snapshot and still
      # attempt CREATE TYPE — raising DuplicateObjectError.  The DO $$ block is
      # atomic at the PostgreSQL level and is the recommended idempotency
      # pattern for enum creation in migration scripts.
      op.execute(sa.text(
          "DO $$ BEGIN "
          "  CREATE TYPE signalstatus AS ENUM "
          "    ('pending', 'active', 'failed', 'permanently_failed', 'duplicate'); "
          "EXCEPTION WHEN duplicate_object THEN null; "
          "END $$;"
      ))

      # if_not_exists=True makes this revision safe to re-run on a database
      # where the schema was previously bootstrapped via Base.metadata.create_all()
      # (i.e. the table exists but the alembic_version row does not).
      op.create_table(
          "signals",
          sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
          sa.Column("signal_id", sa.String(), nullable=False, unique=True),
          sa.Column("symbol", sa.String(), nullable=False),
          sa.Column("direction", sa.String(), nullable=False),
          sa.Column("entry", sa.Float(), nullable=False),
          sa.Column("sl", sa.Float(), nullable=False),
          sa.Column("tp1", sa.Float(), nullable=False),
          sa.Column("tp2", sa.Float(), nullable=False),
          sa.Column("confidence", sa.Integer(), nullable=False),
          sa.Column("reasons", sa.JSON(), nullable=False),
          sa.Column("timeframe", sa.String(), nullable=False),
          sa.Column("received_at", sa.DateTime(timezone=True), nullable=True),
          sa.Column("telegram_message_id", sa.Integer(), nullable=True),
          sa.Column("status", signal_status_enum, nullable=False, server_default="pending"),
          sa.Column("error_message", sa.Text(), nullable=True),
          sa.Column("latency_ms", sa.Integer(), nullable=True),
          if_not_exists=True,
      )

      # Create indexes only if they don't already exist.
      op.execute(sa.text(
          "CREATE INDEX IF NOT EXISTS ix_signals_signal_id ON signals (signal_id);"
      ))
      op.execute(sa.text(
          "CREATE INDEX IF NOT EXISTS ix_signals_status ON signals (status);"
      ))


    def downgrade() -> None:
      op.execute(sa.text("DROP INDEX IF EXISTS ix_signals_status;"))
      op.execute(sa.text("DROP INDEX IF EXISTS ix_signals_signal_id;"))
      op.drop_table("signals")
      op.execute(sa.text("DROP TYPE IF EXISTS signalstatus;"))
    