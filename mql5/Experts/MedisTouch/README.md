# MedisTouch EA — placeholder

This directory is the intended home for the compiled MedisTouch Expert
Advisor (`.mq5` source and/or compiled `.ex5`).

**Status: not yet committed.** The EA is under active development outside
this repo (MQL5 can't be compiled or backtested from the current Android/
Termux dev environment - a Windows VPS/MetaEditor is the planned path to
compile it). Once compiled, the EA should be added here and configured to
call the `telegram-bridge` service's `POST /signal` endpoint (see the root
README's sequence diagram and `telegram-bridge/README.md` for the payload
contract and required `X-API-Key` header).

Do not assume files exist in this folder just because the root README
describes what will go here - check for actual `.mq5`/`.ex5` files, not
just this note.
