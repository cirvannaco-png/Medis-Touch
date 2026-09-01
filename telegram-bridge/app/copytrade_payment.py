"""Payment -> entitlement -> adaptive copy-trading service.

The service deliberately keeps payment, Telegram membership and broker
execution as separate states. Copy delivery is pull-based: an EA polls for
currently VALID signals, so a stale/expired/invalidated signal disappears
without relying on Telegram delivery timing.
"""
from datetime import datetime, timedelta, timezone
import hashlib, hmac, os, secrets
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_session
from app.models import Signal, SignalLifecycleStatus
from app.copy_models import Payment, Subscription, Entitlement, CopyAccount, CopyTradeEvent, CopyEventStatus
from app.config import settings

router = APIRouter(prefix="/commerce", tags=["payments-copy-trading"])


def now(): return datetime.now(timezone.utc)

def _duration(plan: str) -> int:
    raw = os.getenv(f"PLAN_{plan.upper()}_DAYS", os.getenv("DEFAULT_PLAN_DAYS", "30"))
    try: return max(1, int(raw))
    except ValueError: return 30

async def api_auth(x_api_key: str = Header(..., alias="X-API-Key")):
    if not secrets.compare_digest(x_api_key, settings.SECRET_KEY):
        raise HTTPException(status_code=401, detail="Invalid API key")

class CheckoutRequest(BaseModel):
    user_id: str = Field(..., min_length=1, max_length=100)
    plan: str = Field(default="monthly", min_length=1, max_length=50)
    amount: float = Field(..., gt=0)
    currency: str = Field(default="KES", min_length=3, max_length=8)

class PaymentWebhook(BaseModel):
    payment_id: str = Field(..., min_length=1, max_length=100)
    user_id: str = Field(..., min_length=1, max_length=100)
    provider: str = Field(default="generic", max_length=40)
    provider_reference: str | None = Field(default=None, max_length=150)
    amount: float = Field(..., gt=0)
    currency: str = Field(default="KES", max_length=8)
    plan: str = Field(default="monthly", max_length=50)
    status: str
    paid_at: datetime | None = None

class AccountRequest(BaseModel):
    account_id: str = Field(..., min_length=1, max_length=120)
    user_id: str = Field(..., min_length=1, max_length=100)
    broker: str = Field(..., min_length=1, max_length=80)
    server: str | None = Field(default=None, max_length=120)
    ea_instance: str | None = Field(default=None, max_length=120)
    risk_mode: str = Field(default="percent", max_length=20)
    risk_value: float = Field(default=0.5, gt=0)

class AckRequest(BaseModel):
    copy_id: str
    status: str
    broker_ticket: str | None = None
    error_message: str | None = None

@router.post("/checkout")
async def create_checkout(payload: CheckoutRequest, session: AsyncSession = Depends(get_session)):
    """Create an idempotent payment intent. A real PSP is attached later by
    signing its callback into /payment/webhook; no broker action occurs here."""
    payment_id = "PAY-" + secrets.token_hex(12)
    session.add(Payment(payment_id=payment_id, user_id=payload.user_id, provider="generic",
                        amount=payload.amount, currency=payload.currency.upper(), plan=payload.plan,
                        status="pending"))
    await session.commit()
    return {"payment_id": payment_id, "status": "pending", "plan": payload.plan,
            "amount": payload.amount, "currency": payload.currency.upper(),
            "webhook": "/commerce/payment/webhook"}

@router.post("/payment/webhook")
async def payment_webhook(request: Request, payload: PaymentWebhook, session: AsyncSession = Depends(get_session)):
    secret = os.getenv("PAYMENT_WEBHOOK_SECRET", "")
    if not secret:
        raise HTTPException(status_code=503, detail="PAYMENT_WEBHOOK_SECRET is not configured")
    body = await request.body()
    signature = request.headers.get("X-Payment-Signature", "")
    expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise HTTPException(status_code=401, detail="Invalid payment signature")

    existing = await session.scalar(select(Payment).where(Payment.payment_id == payload.payment_id))
    if existing and existing.status == "paid":
        return {"status": "already_processed", "payment_id": payload.payment_id}
    payment = existing or Payment(payment_id=payload.payment_id, user_id=payload.user_id,
                                  provider=payload.provider, amount=payload.amount,
                                  currency=payload.currency.upper(), plan=payload.plan)
    payment.status = payload.status.lower()
    payment.provider_reference = payload.provider_reference
    payment.paid_at = payload.paid_at or (now() if payment.status == "paid" else None)
    session.add(payment)

    if payment.status == "paid":
        started = payment.paid_at or now()
        expires = started + timedelta(days=_duration(payment.plan))
        sub = await session.scalar(select(Subscription).where(Subscription.payment_id == payment.payment_id))
        if sub is None:
            sub = Subscription(subscription_id="SUB-" + secrets.token_hex(10), user_id=payment.user_id,
                               plan=payment.plan, payment_id=payment.payment_id)
        sub.status="active"; sub.started_at=started; sub.expires_at=expires
        session.add(sub); await session.flush()
        ent = await session.scalar(select(Entitlement).where(Entitlement.subscription_id == sub.subscription_id))
        if ent is None:
            ent = Entitlement(entitlement_id="ENT-" + secrets.token_hex(10), user_id=payment.user_id,
                              subscription_id=sub.subscription_id, valid_from=started, valid_until=expires)
        ent.status="active"; ent.valid_until=expires; ent.telegram_access=True; ent.signal_access=True; ent.copy_trading=True
        session.add(ent)
    await session.commit()
    return {"status": payment.status, "payment_id": payment.payment_id}

@router.get("/subscription/{user_id}")
async def subscription_status(user_id: str, session: AsyncSession = Depends(get_session)):
    t=now(); ent=await session.scalar(select(Entitlement).where(Entitlement.user_id==user_id).order_by(Entitlement.valid_until.desc()))
    if ent and ent.valid_until <= t and ent.status == "active": ent.status="expired"; await session.commit()
    return {"user_id":user_id,"active":bool(ent and ent.status=="active" and ent.valid_until>t),
            "copy_trading":bool(ent and ent.status=="active" and ent.valid_until>t and ent.copy_trading),
            "valid_until":ent.valid_until if ent else None}

@router.post("/account")
async def register_account(payload: AccountRequest, session: AsyncSession = Depends(get_session), _=Depends(api_auth)):
    ent=await session.scalar(select(Entitlement).where(Entitlement.user_id==payload.user_id, Entitlement.status=="active"))
    if not ent or ent.valid_until<=now() or not ent.copy_trading:
        raise HTTPException(status_code=403, detail="Active copy-trading entitlement required")
    acc=await session.scalar(select(CopyAccount).where(CopyAccount.account_id==payload.account_id))
    if acc is None: acc=CopyAccount(**payload.model_dump())
    else:
        for k,v in payload.model_dump().items(): setattr(acc,k,v)
    acc.last_seen_at=now(); acc.copy_enabled=True; session.add(acc); await session.commit()
    return {"account_id":acc.account_id,"copy_enabled":True}

@router.get("/poll/{account_id}")
async def poll(account_id: str, session: AsyncSession = Depends(get_session), _=Depends(api_auth)):
    """Return only currently-valid signals. Pending copies from signals that
    became stale/expired/invalidated are actively skipped on the same poll."""
    acc=await session.scalar(select(CopyAccount).where(CopyAccount.account_id==account_id))
    if not acc: raise HTTPException(status_code=404, detail="Unknown copy account")
    acc.last_seen_at=now()
    ent=await session.scalar(select(Entitlement).where(Entitlement.user_id==acc.user_id, Entitlement.status=="active"))
    t=now()
    if not ent or ent.valid_until<=t or not ent.copy_trading or not acc.copy_enabled:
        if ent and ent.valid_until<=t: ent.status="expired"
        await session.commit(); return {"events":[],"copy_enabled":False}

    signals=(await session.scalars(select(Signal).where(Signal.status=="active", Signal.lifecycle_status==SignalLifecycleStatus.VALID))).all()
    events=[]
    for sig in signals:
        if sig.expires_at and sig.expires_at<=t: continue
        cid=f"CP-{sig.signal_id}-{acc.account_id}"
        ev=await session.scalar(select(CopyTradeEvent).where(CopyTradeEvent.copy_id==cid))
        if ev is None:
            ev=CopyTradeEvent(copy_id=cid, signal_id=sig.signal_id, account_id=acc.account_id,
                              strategy=(sig.extra or {}).get("strategy") if sig.extra else None,
                              symbol=sig.symbol,direction=sig.direction,entry=sig.entry,sl=sig.sl,
                              tp1=sig.tp1,tp2=sig.tp2,final_tp=(sig.extra or {}).get("final_tp") if sig.extra else None,
                              risk_mode=acc.risk_mode,risk_value=acc.risk_value,status=CopyEventStatus.PENDING.value)
            session.add(ev)
        if ev.status==CopyEventStatus.PENDING.value:
            events.append({"copy_id":cid,"signal_id":sig.signal_id,"symbol":sig.symbol,"direction":sig.direction,
                           "entry":sig.entry,"sl":sig.sl,"tp1":sig.tp1,"tp2":sig.tp2,"final_tp":ev.final_tp,
                           "risk_mode":ev.risk_mode,"risk_value":ev.risk_value})
    await session.commit()
    return {"events":events,"copy_enabled":True}

@router.post("/ack")
async def ack(payload: AckRequest, session: AsyncSession = Depends(get_session), _=Depends(api_auth)):
    ev=await session.scalar(select(CopyTradeEvent).where(CopyTradeEvent.copy_id==payload.copy_id))
    if not ev: raise HTTPException(status_code=404, detail="Unknown copy event")
    ev.status=payload.status; ev.broker_ticket=payload.broker_ticket; ev.error_message=payload.error_message
    if payload.status in {"executed","failed","skipped"}: ev.executed_at=now()
    await session.commit(); return {"copy_id":ev.copy_id,"status":ev.status}

@router.post("/reconcile")
async def reconcile(session: AsyncSession = Depends(get_session), _=Depends(api_auth)):
    """Administrative/idempotent expiry sweep. Schedule this every minute on
    Render/cron; expiry is also enforced during account polling."""
    t=now(); changed=0
    ents=(await session.scalars(select(Entitlement).where(Entitlement.status=="active",Entitlement.valid_until<=t))).all()
    for ent in ents:
        ent.status="expired"; changed+=1
        subs=(await session.scalars(select(Subscription).where(Subscription.subscription_id==ent.subscription_id))).all()
        for sub in subs: sub.status="expired"
    await session.commit(); return {"expired":changed}
