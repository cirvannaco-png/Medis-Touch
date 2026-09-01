"""Payment -> entitlement -> adaptive copy-trading service."""
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
router=APIRouter(prefix="/commerce",tags=["payments-copy-trading"])
def now(): return datetime.now(timezone.utc)
def _duration(plan):
    try:return max(1,int(os.getenv(f"PLAN_{plan.upper()}_DAYS",os.getenv("DEFAULT_PLAN_DAYS","30"))))
    except ValueError:return 30
async def api_auth(x_api_key:str=Header(...,alias="X-API-Key")):
    if not secrets.compare_digest(x_api_key,settings.SECRET_KEY):raise HTTPException(401,"Invalid API key")
class CheckoutRequest(BaseModel):
    user_id:str=Field(...,min_length=1,max_length=100); plan:str=Field("monthly",min_length=1,max_length=50); amount:float=Field(...,gt=0); currency:str=Field("KES",min_length=3,max_length=8)
class PaymentWebhook(BaseModel):
    payment_id:str=Field(...,min_length=1,max_length=100); user_id:str=Field(...,min_length=1,max_length=100); provider:str=Field("generic",max_length=40); provider_reference:str|None=Field(None,max_length=150); amount:float=Field(...,gt=0); currency:str=Field("KES",max_length=8); plan:str=Field("monthly",max_length=50); status:str; paid_at:datetime|None=None
class AccountRequest(BaseModel):
    account_id:str=Field(...,min_length=1,max_length=120); user_id:str=Field(...,min_length=1,max_length=100); broker:str=Field(...,min_length=1,max_length=80); server:str|None=Field(None,max_length=120); ea_instance:str|None=Field(None,max_length=120); risk_mode:str=Field("percent",max_length=20); risk_value:float=Field(.5,gt=0)
class AckRequest(BaseModel):
    copy_id:str; status:str; broker_ticket:str|None=None; error_message:str|None=None
@router.post("/checkout")
async def create_checkout(payload:CheckoutRequest,session:AsyncSession=Depends(get_session)):
    pid="PAY-"+secrets.token_hex(12); session.add(Payment(payment_id=pid,user_id=payload.user_id,provider="generic",amount=payload.amount,currency=payload.currency.upper(),plan=payload.plan,status="pending")); await session.commit(); return {"payment_id":pid,"status":"pending","plan":payload.plan,"amount":payload.amount,"currency":payload.currency.upper(),"webhook":"/commerce/payment/webhook"}
@router.post("/payment/webhook")
async def payment_webhook(request:Request,payload:PaymentWebhook,session:AsyncSession=Depends(get_session)):
    secret=os.getenv("PAYMENT_WEBHOOK_SECRET","")
    if not secret:raise HTTPException(503,"PAYMENT_WEBHOOK_SECRET is not configured")
    body=await request.body(); sig=request.headers.get("X-Payment-Signature",""); expected=hmac.new(secret.encode(),body,hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig,expected):raise HTTPException(401,"Invalid payment signature")
    payment=await session.scalar(select(Payment).where(Payment.payment_id==payload.payment_id))
    if payment and payment.status=="paid":return {"status":"already_processed","payment_id":payload.payment_id}
    if payment is None:payment=Payment(payment_id=payload.payment_id,user_id=payload.user_id,provider=payload.provider,amount=payload.amount,currency=payload.currency.upper(),plan=payload.plan)
    payment.status=payload.status.lower();payment.provider_reference=payload.provider_reference;payment.paid_at=payload.paid_at or (now() if payment.status=="paid" else None);session.add(payment)
    if payment.status=="paid":
        started=payment.paid_at or now();expires=started+timedelta(days=_duration(payment.plan))
        sub=await session.scalar(select(Subscription).where(Subscription.payment_id==payment.payment_id))
        if sub is None:sub=Subscription(subscription_id="SUB-"+secrets.token_hex(10),user_id=payment.user_id,plan=payment.plan,payment_id=payment.payment_id)
        sub.status="active";sub.started_at=started;sub.expires_at=expires;session.add(sub);await session.flush()
        ent=await session.scalar(select(Entitlement).where(Entitlement.subscription_id==sub.subscription_id))
        if ent is None:ent=Entitlement(entitlement_id="ENT-"+secrets.token_hex(10),user_id=payment.user_id,subscription_id=sub.subscription_id,valid_from=started,valid_until=expires)
        ent.status="active";ent.valid_until=expires;ent.telegram_access=True;ent.signal_access=True;ent.copy_trading=True;session.add(ent)
    await session.commit();return {"status":payment.status,"payment_id":payment.payment_id}
@router.get("/subscription/{user_id}")
async def subscription_status(user_id:str,session:AsyncSession=Depends(get_session)):
    ent=await session.scalar(select(Entitlement).where(Entitlement.user_id==user_id).order_by(Entitlement.valid_until.desc()));t=now()
    if ent and ent.status=="active" and ent.valid_until<=t:ent.status="expired";await session.commit()
    active=bool(ent and ent.status=="active" and ent.valid_until>t)
    return {"user_id":user_id,"active":active,"copy_trading":bool(active and ent.copy_trading),"valid_until":ent.valid_until if ent else None}
@router.post("/account")
async def register_account(payload:AccountRequest,session:AsyncSession=Depends(get_session),_=Depends(api_auth)):
    ent=await session.scalar(select(Entitlement).where(Entitlement.user_id==payload.user_id,Entitlement.status=="active"))
    if not ent or ent.valid_until<=now() or not ent.copy_trading:raise HTTPException(403,"Active copy-trading entitlement required")
    acc=await session.scalar(select(CopyAccount).where(CopyAccount.account_id==payload.account_id))
    if acc is None:acc=CopyAccount(**payload.model_dump())
    else:
        for k,v in payload.model_dump().items():setattr(acc,k,v)
    acc.last_seen_at=now();acc.copy_enabled=True;session.add(acc);await session.commit();return {"account_id":acc.account_id,"copy_enabled":True}
@router.get("/poll/{account_id}")
async def poll(account_id:str,session:AsyncSession=Depends(get_session),_=Depends(api_auth)):
    acc=await session.scalar(select(CopyAccount).where(CopyAccount.account_id==account_id))
    if not acc:raise HTTPException(404,"Unknown copy account")
    acc.last_seen_at=now();t=now();ent=await session.scalar(select(Entitlement).where(Entitlement.user_id==acc.user_id,Entitlement.status=="active"))
    if not ent or ent.valid_until<=t or not ent.copy_trading or not acc.copy_enabled:
        if ent and ent.valid_until<=t:ent.status="expired"
        await session.commit();return {"events":[],"copy_enabled":False}
    # First kill pending copies whose signal has lost validity.
    pending=(await session.scalars(select(CopyTradeEvent).where(CopyTradeEvent.account_id==acc.account_id,CopyTradeEvent.status==CopyEventStatus.PENDING.value))).all()
    for ev in pending:
        sig=await session.scalar(select(Signal).where(Signal.signal_id==ev.signal_id))
        if not sig or sig.status!="active" or sig.lifecycle_status!=SignalLifecycleStatus.VALID or (sig.expires_at and sig.expires_at<=t):ev.status=CopyEventStatus.SKIPPED.value;ev.error_message="Signal no longer valid";ev.executed_at=t
    signals=(await session.scalars(select(Signal).where(Signal.status=="active",Signal.lifecycle_status==SignalLifecycleStatus.VALID))).all();events=[]
    for sig in signals:
        if sig.expires_at and sig.expires_at<=t:continue
        cid=f"CP-{sig.signal_id}-{acc.account_id}";ev=await session.scalar(select(CopyTradeEvent).where(CopyTradeEvent.copy_id==cid))
        if ev is None:
            extra=sig.extra or {};ev=CopyTradeEvent(copy_id=cid,signal_id=sig.signal_id,account_id=acc.account_id,strategy=extra.get("strategy"),symbol=sig.symbol,direction=sig.direction,entry=sig.entry,sl=sig.sl,tp1=sig.tp1,tp2=sig.tp2,final_tp=extra.get("final_tp"),risk_mode=acc.risk_mode,risk_value=acc.risk_value,status=CopyEventStatus.PENDING.value);session.add(ev)
        if ev.status==CopyEventStatus.PENDING.value:events.append({"copy_id":cid,"signal_id":sig.signal_id,"symbol":sig.symbol,"direction":sig.direction,"entry":sig.entry,"sl":sig.sl,"tp1":sig.tp1,"tp2":sig.tp2,"final_tp":ev.final_tp,"risk_mode":ev.risk_mode,"risk_value":ev.risk_value})
    await session.commit();return {"events":events,"copy_enabled":True}
@router.post("/ack")
async def ack(payload:AckRequest,session:AsyncSession=Depends(get_session),_=Depends(api_auth)):
    ev=await session.scalar(select(CopyTradeEvent).where(CopyTradeEvent.copy_id==payload.copy_id))
    if not ev:raise HTTPException(404,"Unknown copy event")
    ev.status=payload.status;ev.broker_ticket=payload.broker_ticket;ev.error_message=payload.error_message
    if payload.status in {"executed","failed","skipped"}:ev.executed_at=now()
    await session.commit();return {"copy_id":ev.copy_id,"status":ev.status}
@router.post("/reconcile")
async def reconcile(session:AsyncSession=Depends(get_session),_=Depends(api_auth)):
    t=now();changed=0;ents=(await session.scalars(select(Entitlement).where(Entitlement.status=="active",Entitlement.valid_until<=t))).all()
    for ent in ents:ent.status="expired";changed+=1
    pending=(await session.scalars(select(CopyTradeEvent).where(CopyTradeEvent.status==CopyEventStatus.PENDING.value))).all()
    for ev in pending:
        sig=await session.scalar(select(Signal).where(Signal.signal_id==ev.signal_id))
        if not sig or sig.status!="active" or sig.lifecycle_status!=SignalLifecycleStatus.VALID or (sig.expires_at and sig.expires_at<=t):ev.status=CopyEventStatus.SKIPPED.value;ev.error_message="Signal no longer valid";ev.executed_at=t
    await session.commit();return {"expired_entitlements":changed,"invalidated_pending_copies":sum(1 for e in pending if e.status==CopyEventStatus.SKIPPED.value)}
