#!/usr/bin/env bash
# ============================================================
#  3x-UI Telegram Bot — One-Click VPS Installer
#  Run this on a fresh Ubuntu/Debian VPS:
#    bash <(curl -s https://your-host/setup-3xui-bot.sh)
#
#  Or paste the whole script into a .sh file and run:
#    chmod +x setup-3xui-bot.sh && ./setup-3xui-bot.sh
# ============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║    3x-UI Telegram Bot — VPS Installer   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Collect config ──────────────────────────────────────────
echo -e "${YELLOW}Enter configuration values:${NC}"
echo ""

read -p "  📱 Telegram Bot Token (from @BotFather): " TG_BOT_TOKEN
while [ -z "$XUI_API_TOKEN" ]; do
    read -p "  🔑 3x-UI API Token: " XUI_API_TOKEN
    [ -z "$XUI_API_TOKEN" ] && echo -e "     ${RED}⚠ Required${NC}"
done
read -p "  🌐 3x-UI Panel URL (full, e.g. https://IP:PORT/path): " XUI_PANEL_URL
while [ -z "$TG_ALLOWED_USERS" ]; do
    read -p "  👤 Allowed Telegram User IDs (comma-separated, e.g. 123456,789012): " TG_ALLOWED_USERS
    [ -z "$TG_ALLOWED_USERS" ] && echo -e "     ${RED}⚠ Required — bot won't work without at least one ID${NC}"
done
read -p "  🔗 Subscription Base URL (e.g. https://yourdomain.com:2096): " SUB_BASE_URL

echo ""
echo -e "${YELLOW}Review:${NC}"
echo "  Bot Token:     ${TG_BOT_TOKEN:0:8}..."
echo "  API Token:     ${XUI_API_TOKEN:0:8}..."
echo "  Panel URL:     $XUI_PANEL_URL"
echo "  Allowed IDs:   $TG_ALLOWED_USERS"
echo "  Sub Base URL:  $SUB_BASE_URL"
echo ""

read -p "Continue with these values? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    err "Aborted."
    exit 0
fi

# ── Install system dependencies ─────────────────────────────
log "Updating system & installing Python..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv python3-dev > /dev/null

# ── Create bot directory ────────────────────────────────────
BOT_DIR="/opt/3xui-telegram-bot"
log "Creating bot directory: $BOT_DIR"
mkdir -p "$BOT_DIR"

# ── Write .env file ─────────────────────────────────────────
log "Writing .env configuration..."
cat > "$BOT_DIR/.env" << ENVEOF
PANEL_URL=$XUI_PANEL_URL
API_TOKEN=$XUI_API_TOKEN
ALLOWED_USERS=$TG_ALLOWED_USERS
SUB_BASE_URL=$SUB_BASE_URL
ENVEOF

# ── Write requirements.txt ──────────────────────────────────
cat > "$BOT_DIR/requirements.txt" << 'REQEOF'
python-telegram-bot>=20.0
requests
urllib3
REQEOF

# ── Write bot.py ────────────────────────────────────────────
log "Writing bot.py..."
cat > "$BOT_DIR/bot.py" << 'BOTPYEOF'
#!/usr/bin/env python3
"""
3x-UI Telegram Bot — Manage your 3x-UI panel via Telegram.
Button-based UI + batch text-create support.
Configuration is read from .env file.
"""

import os
import json
import uuid
import logging
from datetime import datetime, timezone
from urllib.parse import urlparse

import requests
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, filters, ContextTypes
)

# ── Load .env ───────────────────────────────────────────────
def load_env(path: str = None):
    """Simple .env loader (no external deps needed)."""
    if path is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.exists(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = val

load_env()

# ── Config ──────────────────────────────────────────────────
PANEL_URL = os.getenv("PANEL_URL", "")
API_TOKEN = os.getenv("API_TOKEN", "")
API_BASE = f"{PANEL_URL}/panel/api"

_p = urlparse(PANEL_URL) if PANEL_URL else urlparse("http://localhost")
SUB_BASE = os.getenv("SUB_BASE_URL", f"{_p.scheme}://{_p.hostname}:2096")

ALLOWED_USERS = set()
_raw_users = os.getenv("ALLOWED_USERS", "")
if _raw_users:
    ALLOWED_USERS = {int(u.strip()) for u in _raw_users.split(",") if u.strip()}
# If still empty, reject everyone (must set ALLOWED_USERS in .env)
if not ALLOWED_USERS:
    ALLOWED_USERS = None  # None = reject all

# ── Logging ─────────────────────────────────────────────────
logging.basicConfig(format="%(asctime)s [%(levelname)s] %(message)s", level=logging.INFO)
logger = logging.getLogger("3xui-bot")

# ── API Helpers ─────────────────────────────────────────────
HEADERS = {
    "Authorization": f"Bearer {API_TOKEN}",
    "Content-Type": "application/json",
    "Accept": "application/json",
}

def api_get(path: str) -> dict:
    url = f"{API_BASE}/{path.lstrip('/')}"
    try:
        r = requests.get(url, headers=HEADERS, timeout=15, verify=False)
        return r.json()
    except Exception as e:
        logger.error(f"GET {path}: {e}")
        return {"success": False, "msg": str(e)}

def api_post(path: str, data: dict = None) -> dict:
    url = f"{API_BASE}/{path.lstrip('/')}"
    try:
        r = requests.post(url, headers=HEADERS, json=data or {}, timeout=15, verify=False)
        return r.json()
    except Exception as e:
        logger.error(f"POST {path}: {e}")
        return {"success": False, "msg": str(e)}

def fmt_bytes(b: int) -> str:
    if b >= 1024**4: return f"{b / 1024**4:.1f} TB"
    if b >= 1024**3: return f"{b / 1024**3:.1f} GB"
    if b >= 1024**2: return f"{b / 1024**2:.1f} MB"
    if b >= 1024: return f"{b / 1024:.0f} KB"
    return f"{b} B"

def fmt_uptime(sec: int) -> str:
    d, h, m = sec // 86400, (sec % 86400) // 3600, (sec % 3600) // 60
    parts = [f"{d}d" if d else "", f"{h}h" if h else "", f"{m}m" if m else ""]
    return " ".join(p for p in parts if p) or "<1m"

def fmt_timestamp(ms: int) -> str:
    if not ms or ms == 0: return "never"
    try:
        return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")
    except:
        return str(ms)

def sub_link(sub_id: str) -> str:
    return f"{SUB_BASE}/sub/{sub_id}"

# ── Auth ────────────────────────────────────────────────────
def check_auth(update: Update) -> bool:
    if ALLOWED_USERS is None: return False  # reject if not configured
    if not ALLOWED_USERS: return True       # empty set = allow all (legacy)
    return update.effective_user.id in ALLOWED_USERS

# ── Menus ───────────────────────────────────────────────────
MAIN_MENU = InlineKeyboardMarkup([
    [InlineKeyboardButton("📊 Server Status", callback_data="m_status")],
    [InlineKeyboardButton("📡 List Inbounds", callback_data="m_inbounds")],
    [InlineKeyboardButton("👤 List Clients", callback_data="m_clients")],
    [InlineKeyboardButton("➕ Add Client", callback_data="m_addclient")],
    [InlineKeyboardButton("❌ Delete Client", callback_data="m_delclient")],
    [InlineKeyboardButton("🔄 Reset Traffic", callback_data="m_reset")],
])

BACK_BTN = InlineKeyboardMarkup([
    [InlineKeyboardButton("🏠 Main Menu", callback_data="m_start")],
])

MAIN_TEXT = "🐾 <b>3x-UI Bot</b>\n━━━━━━━━━━━━━━━━\nChoose an action:"
CLIENTS_PER_PAGE = 8

# ── Commands ────────────────────────────────────────────────
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update): return
    context.user_data.clear()
    await update.message.reply_text(MAIN_TEXT, parse_mode="HTML", reply_markup=MAIN_MENU)

async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = (
        "🐾 <b>3x-UI Bot</b>\n━━━━━━━━━━━━━━━━\n\n"
        "<b>Buttons:</b> Tap to navigate\n\n"
        "<b>Fast Create:</b> Send 5-line template:\n"
        "<code>create\nname\n150gb\n31days\n5</code>\n\n"
        "<b>Commands:</b>\n"
        "/start — Main menu\n"
        "/traffic email — View traffic"
    )
    await update.message.reply_text(text, parse_mode="HTML")

# ── Menu Dispatcher ─────────────────────────────────────────
async def menu_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    if not check_auth(update):
        await query.edit_message_text("⛔ Not authorized.")
        return
    data = query.data
    if data == "m_start":
        context.user_data.clear()
        await query.edit_message_text(MAIN_TEXT, parse_mode="HTML", reply_markup=MAIN_MENU)
    elif data == "m_status":
        await show_status(query)
    elif data == "m_inbounds":
        await show_inbounds(query)
    elif data == "m_clients":
        context.user_data["clients_page"] = 0
        await show_clients(query, context, page=0)
    elif data.startswith("clients_page_"):
        page = int(data.split("_")[-1])
        await show_clients(query, context, page=page)
    elif data == "m_addclient":
        await start_add_client(query, context)
    elif data == "m_delclient":
        await show_delclient(query)
    elif data == "m_reset":
        await show_reset(query, context)

# ── Status ──────────────────────────────────────────────────
async def show_status(query):
    data = api_get("server/status")
    if not data.get("success"):
        await query.edit_message_text(f"❌ Error: {data.get('msg','Unknown')}", reply_markup=BACK_BTN)
        return
    s = data["obj"]
    mem, disk, net = s.get("mem",{}), s.get("disk",{}), s.get("netTraffic",{})
    text = (
        f"🖥 <b>Server Status</b>\n━━━━━━━━━━━━━━━━\n"
        f"🔖 Panel: v{s.get('panelVersion','?')}\n"
        f"⏰ Uptime: {fmt_uptime(s.get('uptime',0))}\n\n"
        f"📊 CPU: {s.get('cpu',0):.1f}% ({s.get('cpuCores','?')} cores)\n"
        f"🧠 RAM: {fmt_bytes(mem.get('current',0))} / {fmt_bytes(mem.get('total',0))}\n"
        f"💾 Disk: {fmt_bytes(disk.get('current',0))} / {fmt_bytes(disk.get('total',0))}\n\n"
        f"⬆️ Sent: {fmt_bytes(net.get('sent',0))}  ⬇️ Recv: {fmt_bytes(net.get('recv',0))}"
    )
    await query.edit_message_text(text, parse_mode="HTML", reply_markup=BACK_BTN)

# ── Inbounds ────────────────────────────────────────────────
async def show_inbounds(query):
    data = api_get("inbounds/list")
    if not data.get("success"):
        await query.edit_message_text(f"❌ Error: {data.get('msg','Unknown')}", reply_markup=BACK_BTN)
        return
    inbounds = data.get("obj", [])
    if not inbounds:
        await query.edit_message_text("📡 No inbounds found.", reply_markup=BACK_BTN)
        return
    lines = [f"📡 <b>Inbounds ({len(inbounds)})</b>\n━━━━━━━━━━━━━━━━"]
    for ib in inbounds:
        up, down = fmt_bytes(ib.get("up",0)), fmt_bytes(ib.get("down",0))
        n = len(ib.get("clientStats",[]))
        s = "🟢" if ib.get("enable") else "🔴"
        lines.append(f"{s} <b>#{ib['id']}</b> — {ib.get('protocol','?').upper()} :{ib.get('port','?')}\n   {ib.get('remark','')} | {n} clients | ⬆️{up} ⬇️{down}")
    await query.edit_message_text("\n".join(lines), parse_mode="HTML", reply_markup=BACK_BTN)

# ── Clients ─────────────────────────────────────────────────
async def show_clients(query, context, page=0):
    data = api_get("clients/list")
    if not data.get("success"):
        await query.edit_message_text(f"❌ Error: {data.get('msg','Unknown')}", reply_markup=BACK_BTN)
        return
    clients = data.get("obj", [])
    if not clients:
        await query.edit_message_text("👤 No clients found.", reply_markup=BACK_BTN)
        return
    clients.sort(key=lambda c: c.get("email",""))
    tp = max(1, (len(clients) + CLIENTS_PER_PAGE - 1) // CLIENTS_PER_PAGE)
    page = max(0, min(page, tp - 1))
    start = page * CLIENTS_PER_PAGE
    chunk = clients[start:start + CLIENTS_PER_PAGE]
    lines = [f"👤 <b>Clients ({start+1}-{start+len(chunk)} of {len(clients)})</b>\n━━━━━━━━━━━━━━━━"]
    for c in chunk:
        email = c.get("email","?")
        s = "🟢" if c.get("enable") else "🔴"
        up, dn = fmt_bytes(c.get("up",0)), fmt_bytes(c.get("down",0))
        total = c.get("total",0)
        ts = f" / {fmt_bytes(total)}" if total > 0 else ""
        exp = c.get("expiryTime",0)
        es = f" | ⏳{fmt_timestamp(exp)}" if exp > 0 else ""
        lines.append(f"{s} <b>{email}</b> — ⬆️{up} ⬇️{dn}{ts}{es}")
    nav = []
    if tp > 1:
        row = []
        if page > 0: row.append(InlineKeyboardButton("⬅️ Prev", callback_data=f"clients_page_{page-1}"))
        row.append(InlineKeyboardButton(f"📄 {page+1}/{tp}", callback_data="noop"))
        if page < tp - 1: row.append(InlineKeyboardButton("Next ➡️", callback_data=f"clients_page_{page+1}"))
        nav.append(row)
    nav.append([InlineKeyboardButton("🏠 Main Menu", callback_data="m_start")])
    await query.edit_message_text("\n".join(lines), parse_mode="HTML", reply_markup=InlineKeyboardMarkup(nav))

# ── Add Client (step-by-step button flow) ───────────────────
async def start_add_client(query, context):
    data = api_get("inbounds/list")
    if not data.get("success"):
        await query.edit_message_text("❌ Failed to load inbounds.", reply_markup=BACK_BTN); return
    inbounds = data.get("obj", [])
    if not inbounds:
        await query.edit_message_text("📡 No inbounds available.", reply_markup=BACK_BTN); return
    context.user_data["add"] = {"inbounds": inbounds, "step": "name"}
    await query.edit_message_text(
        "➕ <b>Add New Client</b>\n\n<b>Step 1:</b> Enter customer name:\n<i>(Used as email & subscription ID)</i>",
        parse_mode="HTML")

async def handle_addflow_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query; await query.answer()
    data = query.data
    add = context.user_data.get("add", {})
    step = add.get("step","")
    if data == "addflow_cancel":
        context.user_data.pop("add",None)
        await query.edit_message_text("❌ Cancelled.", reply_markup=BACK_BTN); return
    if step == "inbound" and data.startswith("addflow_ib_"):
        iid = int(data.split("_")[-1])
        add["inbound_id"] = iid
        ib = next((i for i in add.get("inbounds",[]) if i["id"]==iid), None)
        add["step"] = "expiry"
        await query.edit_message_text(
            f"✅ Customer: <b>{add['name']}</b>\n✅ Inbound: <b>#{iid}</b> ({ib.get('protocol','?').upper() if ib else '?'})\n\n<b>Step 3:</b> Expiry in days (0=never):",
            parse_mode="HTML"); return
    if step == "confirm" and data == "addflow_confirm":
        await do_add_client(query, context); return

async def do_add_client(query, context):
    add = context.user_data.pop("add",{})
    name = add.get("name",""); iid = add.get("inbound_id",0)
    ed = add.get("expiry",0); lg = add.get("limit",0)
    # Final duplicate check
    existing = api_get("clients/list")
    if existing.get("success"):
        for c in existing.get("obj",[]):
            if c.get("email","").lower() == name.lower():
                await query.edit_message_text(f"⚠️ Duplicate — <b>{name}</b> already exists.", parse_mode="HTML", reply_markup=BACK_BTN); return
    ems = int((datetime.now(timezone.utc).timestamp() + ed*86400)*1000) if ed>0 else 0
    tb = int(lg*1024**3) if lg>0 else 0
    uid = str(uuid.uuid4())
    payload = {"client":{"email":name,"enable":True,"id":uid,"flow":"","limitIp":0,"totalGB":tb,"expiryTime":ems,"subId":name},"inboundIds":[iid]}
    res = api_post("clients/add", payload)
    if res.get("success"):
        link = sub_link(name)
        text = (f"✅ <b>Client Created!</b>\n━━━━━━━━━━━━━━━━\n👤 Name/Email: <b>{name}</b>\n📡 Inbound: <b>#{iid}</b>\n⏳ Expiry: <b>{ed}d</b>\n📦 Limit: <b>{lg}GB</b>\n🔑 UUID: <code>{uid}</code>\n\n🔗 <b>Sub Link:</b>\n<code>{link}</code>")
    else:
        text = f"❌ Failed: {res.get('msg','Unknown')}"
    await query.edit_message_text(text, parse_mode="HTML", reply_markup=BACK_BTN)

# ── Batch Create (text template) ────────────────────────────
async def batch_create_client(update: Update, context: ContextTypes.DEFAULT_TYPE, lines: list):
    context.user_data.pop("add",None)
    _, nr, lr, er, ir = lines
    name = "".join(c for c in nr.replace(" ","_") if c.isalnum() or c in "_-")
    if len(name)<2: await update.message.reply_text("⚠️ Name too short."); return
    # Check duplicate
    ex = api_get("clients/list")
    if ex.get("success"):
        for c in ex.get("obj",[]):
            if c.get("email","").lower()==name.lower():
                await update.message.reply_text(f"⚠️ Duplicate — <b>{name}</b> already exists.", parse_mode="HTML"); return
    # Parse limit
    ll = lr.lower().strip()
    if ll in ("0","","unlimited","∞","none","nolimit"): limit_gb = 0.0
    elif ll.endswith("mb"): limit_gb = float(ll.replace("mb","").strip())/1024
    else:
        clean = ll.replace("gb","").replace("g","").strip()
        try: limit_gb = float(clean) if clean else 0.0
        except ValueError: await update.message.reply_text(f"⚠️ Bad limit: <code>{lr}</code>", parse_mode="HTML"); return
    # Parse expiry
    es = er.lower().replace("days","").replace("day","").replace("d","").strip()
    expiry_days = 0 if es in ("0","","never","∞","none") else int(es)
    if expiry_days<0: await update.message.reply_text("⚠️ Expiry must be ≥ 0."); return
    # Parse inbound
    try: iid = int(ir.replace("#","").strip())
    except ValueError: await update.message.reply_text(f"⚠️ Bad inbound: <code>{ir}</code>", parse_mode="HTML"); return
    # Validate inbound
    ibd = api_get("inbounds/list")
    if not ibd.get("success"): await update.message.reply_text("❌ Failed to load inbounds."); return
    ib = next((i for i in ibd.get("obj",[]) if i["id"]==iid), None)
    if not ib:
        ids = ", ".join(f"#{i['id']}" for i in ibd.get("obj",[]))
        await update.message.reply_text(f"⚠️ Inbound #{iid} not found.\nAvailable: {ids}", parse_mode="HTML"); return
    # Create
    ems = int((datetime.now(timezone.utc).timestamp()+expiry_days*86400)*1000) if expiry_days>0 else 0
    tb = int(limit_gb*1024**3) if limit_gb>0 else 0
    uid = str(uuid.uuid4())
    payload = {"client":{"email":name,"enable":True,"id":uid,"flow":"","limitIp":0,"totalGB":tb,"expiryTime":ems,"subId":name},"inboundIds":[iid]}
    res = api_post("clients/add", payload)
    if res.get("success"):
        link = sub_link(name)
        text = (f"✅ <b>Client Created!</b>\n━━━━━━━━━━━━━━━━\n👤 Name: <b>{name}</b>\n📡 Inbound: <b>#{iid}</b> ({ib.get('protocol','?').upper()})\n⏳ Expiry: <b>{expiry_days}d</b>\n📦 Limit: <b>{limit_gb}GB</b>\n🔑 UUID: <code>{uid}</code>\n\n🔗 <b>Sub Link:</b>\n<code>{link}</code>")
    else:
        text = f"❌ Failed: {res.get('msg','Unknown')}"
    await update.message.reply_text(text, parse_mode="HTML", reply_markup=MAIN_MENU)

# ── Text Handler ────────────────────────────────────────────
async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = update.message.text.strip()
    # Batch create template (5 lines, starts with "create")
    lines = [l.strip() for l in text.split("\n") if l.strip()]
    if len(lines)==5 and lines[0].lower()=="create":
        await batch_create_client(update, context, lines); return
    # Step-by-step flow
    add = context.user_data.get("add",{})
    step = add.get("step","")
    if step=="name":
        raw = update.message.text.strip()
        name = "".join(c for c in raw.replace(" ","_") if c.isalnum() or c in "_-")
        if len(name)<2: await update.message.reply_text("⚠️ Name too short. Try again:"); return
        ex = api_get("clients/list")
        if ex.get("success"):
            for c in ex.get("obj",[]):
                if c.get("email","").lower()==name.lower():
                    await update.message.reply_text(f"⚠️ Duplicate — <b>{name}</b> exists. New name:", parse_mode="HTML"); return
        add["name"]=name; add["step"]="inbound"
        inbounds=add["inbounds"]
        kb=[]; [kb.append([InlineKeyboardButton(f"#{i['id']} {i.get('protocol','?').upper()} :{i['port']}", callback_data=f"addflow_ib_{i['id']}")]) for i in inbounds]
        kb.append([InlineKeyboardButton("❌ Cancel", callback_data="addflow_cancel")])
        await update.message.reply_text(f"✅ Customer: <b>{name}</b>\n\n<b>Step 2:</b> Select inbound:", parse_mode="HTML", reply_markup=InlineKeyboardMarkup(kb)); return
    if step=="expiry":
        try:
            d=int(update.message.text.strip())
            if d<0: raise ValueError
        except ValueError: await update.message.reply_text("⚠️ Enter a number (0=never):"); return
        add["expiry"]=d; add["step"]="limit"
        await update.message.reply_text(f"✅ Expiry: <b>{d}d</b>\n\n<b>Step 4:</b> Data limit in GB (0=unlimited):", parse_mode="HTML"); return
    if step=="limit":
        try:
            g=float(update.message.text.strip())
            if g<0: raise ValueError
        except ValueError: await update.message.reply_text("⚠️ Enter a number (0=unlimited):"); return
        add["limit"]=g; add["step"]="confirm"
        ls=f"{g}GB" if g>0 else "Unlimited"; es=f"{add['expiry']}d" if add['expiry']>0 else "Never"
        kb=[[InlineKeyboardButton("✅ Confirm", callback_data="addflow_confirm")],[InlineKeyboardButton("❌ Cancel", callback_data="addflow_cancel")]]
        await update.message.reply_text(f"📋 <b>Confirm</b>\n━━━━━━━━━━━━━━━━\n👤 <b>{add['name']}</b>\n📡 #{add['inbound_id']}\n⏳ {es}\n📦 {ls}", parse_mode="HTML", reply_markup=InlineKeyboardMarkup(kb)); return
    # No active flow → show menu
    await update.message.reply_text(MAIN_TEXT, parse_mode="HTML", reply_markup=MAIN_MENU)

# ── Delete ──────────────────────────────────────────────────
async def show_delclient(query):
    data = api_get("clients/list")
    if not data.get("success"): await query.edit_message_text("❌ Failed.", reply_markup=BACK_BTN); return
    clients = data.get("obj",[])
    if not clients: await query.edit_message_text("👤 No clients.", reply_markup=BACK_BTN); return
    clients.sort(key=lambda c: c.get("email",""))
    kb=[]; [kb.append([InlineKeyboardButton(f"{'🟢' if c.get('enable') else '🔴'} {c.get('email','?')}", callback_data=f"del_{c['id']}_{c.get('email','?')}")]) for c in clients]
    kb.append([InlineKeyboardButton("🏠 Main Menu", callback_data="m_start")])
    await query.edit_message_text("❌ <b>Delete Client</b>\nSelect:", parse_mode="HTML", reply_markup=InlineKeyboardMarkup(kb))

async def do_delete(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query=update.callback_query; await query.answer()
    email = query.data.split("_",2)[2]
    res = api_post(f"clients/del/{email}", {"email":email})
    t = f"✅ <b>{email}</b> deleted." if res.get("success") else f"❌ Failed: {res.get('msg','?')}"
    await query.edit_message_text(t, parse_mode="HTML", reply_markup=BACK_BTN)

# ── Reset ───────────────────────────────────────────────────
async def show_reset(query, context):
    data = api_get("clients/list")
    clients = data.get("obj",[]) if data.get("success") else []
    kb=[[InlineKeyboardButton("🔄 Reset ALL", callback_data="reset_all")]]
    if clients:
        clients.sort(key=lambda c: c.get("email",""))
        [kb.append([InlineKeyboardButton(f"↩️ {c.get('email','?')}", callback_data=f"reset_one_{c.get('email','?')}")]) for c in clients[:15]]
    kb.append([InlineKeyboardButton("🏠 Main Menu", callback_data="m_start")])
    await query.edit_message_text("🔄 <b>Reset Traffic</b>\nSelect:", parse_mode="HTML", reply_markup=InlineKeyboardMarkup(kb))

async def do_reset(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query=update.callback_query; await query.answer()
    d=query.data
    if d=="reset_all":
        res=api_post("inbounds/resetAllTraffics")
        t="✅ All reset." if res.get("success") else f"❌ {res.get('msg','?')}"
    else:
        email=d[10:]
        res=api_post(f"inbounds/resetClientTraffic/{email}")
        t=f"✅ <b>{email}</b> reset." if res.get("success") else f"❌ {res.get('msg','?')}"
    await query.edit_message_text(t, parse_mode="HTML", reply_markup=BACK_BTN)

# ── Traffic ─────────────────────────────────────────────────
async def cmd_traffic(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update): return
    if not context.args: await update.message.reply_text("ℹ️ <code>/traffic email</code>", parse_mode="HTML"); return
    email=context.args[0]
    msg=await update.message.reply_text(f"⏳ <b>{email}</b>...", parse_mode="HTML")
    data=api_get(f"clients/traffic/{email}")
    if not data.get("success") or not data.get("obj"): await msg.edit_text(f"❌ <b>{email}</b> not found.", parse_mode="HTML"); return
    c=data["obj"]
    s="🟢 Active" if c.get("enable") else "🔴 Disabled"
    total=c.get("total",0); ts=fmt_bytes(total) if total>0 else "∞"
    await msg.edit_text(f"📈 <b>{email}</b>\n━━━━━━━━━━━━━━━━\n{s}\n⬆️ {fmt_bytes(c.get('up',0))}\n⬇️ {fmt_bytes(c.get('down',0))}\n📦 {ts}\n⏳ {fmt_timestamp(c.get('expiryTime',0))}\n🕐 {fmt_timestamp(c.get('lastOnline',0))}", parse_mode="HTML")

# ── Noop / Error ────────────────────────────────────────────
async def noop(update, context): await update.callback_query.answer()
async def error_handler(update, context): logger.error(f"Error: {context.error}", exc_info=True)

# ── Main ────────────────────────────────────────────────────
def main():
    import urllib3; urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    app = Application.builder().token(os.getenv("BOT_TOKEN","")).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CommandHandler("traffic", cmd_traffic))
    app.add_handler(CallbackQueryHandler(menu_handler, pattern=r"^m_"))
    app.add_handler(CallbackQueryHandler(handle_addflow_cb, pattern=r"^addflow_"))
    app.add_handler(CallbackQueryHandler(do_delete, pattern=r"^del_"))
    app.add_handler(CallbackQueryHandler(do_reset, pattern=r"^reset_"))
    app.add_handler(CallbackQueryHandler(menu_handler, pattern=r"^clients_page_"))
    app.add_handler(CallbackQueryHandler(noop, pattern=r"^noop$"))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    app.add_error_handler(error_handler)
    logger.info("🤖 3x-UI Bot starting...")
    logger.info(f"   Panel: {PANEL_URL}")
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
BOTPYEOF

# ── Set BOT_TOKEN in .env ───────────────────────────────────
echo "BOT_TOKEN=$TG_BOT_TOKEN" >> "$BOT_DIR/.env"

# ── Create venv and install deps ────────────────────────────
log "Creating Python virtual environment..."
python3 -m venv "$BOT_DIR/venv"
source "$BOT_DIR/venv/bin/activate"
pip install --upgrade pip -q
pip install -r "$BOT_DIR/requirements.txt" -q

# ── Create systemd service ──────────────────────────────────
log "Creating systemd service..."
cat > "/etc/systemd/system/3xui-telegram-bot.service" << UNITEOF
[Unit]
Description=3x-UI Telegram Bot
After=network.target

[Service]
User=root
WorkingDirectory=$BOT_DIR
EnvironmentFile=$BOT_DIR/.env
ExecStart=$BOT_DIR/venv/bin/python $BOT_DIR/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable 3xui-telegram-bot.service
systemctl start 3xui-telegram-bot.service
sleep 3

# ── Verify ──────────────────────────────────────────────────
if systemctl is-active --quiet 3xui-telegram-bot.service; then
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ Bot installed & running!             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    info "Bot Directory: $BOT_DIR"
    info "Status: systemctl status 3xui-telegram-bot"
    info "Logs:   journalctl -u 3xui-telegram-bot -f"
    echo ""
    info "Send /start to your bot on Telegram to begin."
else
    err "Bot failed to start. Check logs:"
    journalctl -u 3xui-telegram-bot --no-pager -n 20
fi
