# Reference reading of docs/IMPORT_NEAR.md (draft 8), used to write the expected files under
# conformance/import/. Not shipped. Three layers, as in the apps:
#   scan   — the file → top-level elements (shared by every source)
#   near   — detect + parse → the source-neutral intermediate
#   writer — intermediate → rows and the summary; knows nothing about the source
#
#   python3 -I reference_import.py <file> [--store store.json] [--json]
import json, math, sys
from urllib.parse import urlsplit

MAX_ELEMENT_BYTES = 64 * 1024 * 1024
MAX_DEPTH = 64

# ── scan ─────────────────────────────────────────────────────────────────────────────────
class Rejected(Exception):
    pass

WRONG_FILE = "wrong-file"

def scan(raw):
    """Yields ('element', bytes, depth) | ('over',) | ('broken',) for each top-level element of a JSON array.
    An element over a cap (MAX_ELEMENT_BYTES of JSON text, or deeper than MAX_DEPTH) is skipped unparsed:
    ('over',), and the read goes on. The first element within the caps must be whole and parse, or the
    file is rejected. A later element that is
    cut off or does not parse yields 'broken' and ends the read. Bytes after the closing ']' are
    ignored. A leading UTF-8 BOM is skipped."""
    b = raw[3:] if raw[:3] == b"\xef\xbb\xbf" else raw
    n = len(b)
    def ws(i):
        while i < n and b[i] in b" \t\r\n": i += 1
        return i
    def element_end(i):
        """(end, depth) of the element starting at i, or None if the file ends inside it."""
        c = b[i]
        if c in b"[{":
            depth = maxd = 0; in_str = esc = False
            while i < n:
                c = b[i]
                if in_str:
                    if esc: esc = False
                    elif c == 0x5C: esc = True
                    elif c == 0x22: in_str = False
                elif c == 0x22: in_str = True
                elif c in b"[{": depth += 1; maxd = max(maxd, depth)
                elif c in b"]}":
                    depth -= 1
                    if depth == 0: return i + 1, maxd
                i += 1
            return None
        if c == 0x22:
            i += 1; esc = False
            while i < n:
                if esc: esc = False
                elif b[i] == 0x5C: esc = True
                elif b[i] == 0x22: return i + 1, 0
                i += 1
            return None
        j = i
        while j < n and b[j] not in b",] \t\r\n": j += 1
        return (j, 0) if j < n else None
    i = ws(0)
    if i >= n or b[i] != 0x5B: raise Rejected(WRONG_FILE)
    i = ws(i + 1)
    if i < n and b[i] == 0x5D: return
    first = True
    while True:
        i = ws(i)
        if i >= n:                                  # cut off between elements: nothing partial
            if first: raise Rejected(WRONG_FILE)
            return
        end = element_end(i)
        if end is not None and (end[0] - i > MAX_ELEMENT_BYTES or end[1] > MAX_DEPTH):
            yield ("over",)
            i = ws(end[0])
            if i < n and b[i] == 0x2C: i += 1; continue
            if i < n and b[i] == 0x5D: return
            if i >= n:
                if first: raise Rejected(WRONG_FILE)
                return
            yield ("broken",); return
        elem = b[i:end[0]] if end else b""
        try:
            if end is None: raise ValueError
            json.loads(elem.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            if first: raise Rejected(WRONG_FILE)
            yield ("broken",); return
        yield ("element", elem, end[1]); first = False
        i = ws(end[0])
        if i < n and b[i] == 0x2C: i += 1; continue
        if i < n and b[i] == 0x5D: return
        if i >= n: return                           # whole elements, no closing bracket
        yield ("broken",); return

# ── near ─────────────────────────────────────────────────────────────────────────────────
def near_detect(first):
    if isinstance(first, dict) and "data" in first: return "near-full"
    if isinstance(first, dict) and "type" in first: return "near-chat"
    return None

def _int(v): return isinstance(v, int) and not isinstance(v, bool)
def _str(v): return isinstance(v, str)

def readable(i):
    if not isinstance(i, dict) or not _str(i.get("id")) or not _str(i.get("response_id")) or not _int(i.get("created_at")):
        return False
    if i.get("type") == "message":
        if not isinstance(i.get("content"), list) or i.get("role") not in ("user", "assistant", "system"): return False
        if i.get("status") in ("failed", "pending"): return False
    return True

def prev_of(i):
    p = i.get("previous_response_id")
    return p if _str(p) and p else None

def path_items(items):
    """near's combineMessagesById + findLastResponseId. None when no item can be a root (a cycle)."""
    rids = {i["response_id"] for i in items}
    nodes = {}; root = None
    def node(r): return nodes.setdefault(r, {"next": [], "parent": None, "has": False})
    for i in items:
        n = node(i["response_id"]); n["has"] = True
        p = prev_of(i)
        if root is None and (p is None or p not in rids): root = i["response_id"]
        if p is not None:
            n["parent"] = p
            if i["response_id"] not in node(p)["next"]: node(p)["next"].append(i["response_id"])
        nx = i.get("next_response_ids")
        for x in (nx if isinstance(nx, list) else []):
            if _str(x) and x not in n["next"]: n["next"].append(x)
    if root is None: return None
    best = [0, root]; seen = set()
    def dfs(r, d):                         # iterative to survive long chains
        st = [(r, d)]
        while st:
            r, d = st.pop()
            if r not in nodes or r in seen or not nodes[r]["has"]: continue   # ids with no readable items are skipped
            seen.add(r)
            if d > best[0]: best[:] = [d, r]
            for x in reversed(nodes[r]["next"]): st.append((x, d + 1))
    dfs(root, 0)
    cur = best[1]; path = []
    while cur and cur in nodes and cur not in path and nodes[cur]["has"]:
        path.append(cur); cur = nodes[cur]["parent"]
    return [i for i in items if i["response_id"] in path]

def near_message(i, items_in_response):
    parts_out = []; placeholders = []
    for p in i["content"]:
        if not isinstance(p, dict): continue
        t = p.get("type")
        if t in ("input_text", "output_text"):
            if _str(p.get("text")) and p["text"]: parts_out.append(("text", p["text"]))
        else:
            kind = "image" if t == "input_image" else "file"
            nm = p.get("name") if _str(p.get("name")) and p.get("name") else (p.get("filename") if _str(p.get("filename")) and p.get("filename") else None)
            data_url = None
            if kind == "image":
                u = p.get("image_url")
                u = u if _str(u) else (u.get("url") if isinstance(u, dict) and _str(u.get("url")) else None)
                data_url = u if u and u.startswith("data:") else None
            placeholders.append({"kind": kind, "name": nm}); parts_out.append(("placeholder", kind, nm, data_url))
    sources = []
    if i["role"] == "assistant":
        for p in i["content"]:
            if not isinstance(p, dict): continue
            ann = p.get("annotations")
            for a in (ann if isinstance(ann, list) else []):
                if isinstance(a, dict) and a.get("type") == "url_citation" and _str(a.get("url")) and a["url"]:
                    sources.append({"url": a["url"], "title": a["title"] if _str(a.get("title")) and a["title"] else None})
        for w in items_in_response:
            if w.get("type") == "web_search_call":
                act = w.get("action") if isinstance(w.get("action"), dict) else {}
                srcs = act.get("sources")
                for s in (srcs if isinstance(srcs, list) else []):
                    if isinstance(s, dict) and _str(s.get("url")) and s["url"]:
                        sources.append({"url": s["url"], "title": None})
    return {"sourceId": i["id"], "role": i["role"], "parts": parts_out, "placeholders": placeholders,
            "createdAt": i["created_at"] * 1000, "sources": sources}

def near_chat(source_id, title, created_at, data, legacy, may_be_incomplete=False, skipped_before=0):
    skipped = skipped_before; items = []; ids = set()
    for n, i in enumerate(data):
        if readable(i) and i["id"] not in ids: ids.add(i["id"]); items.append((n, i))
        else: skipped += 1
    ordered = [i for _, i in items]
    if not legacy:
        keep = path_items(ordered)
        if keep is not None:
            pos = {id(i): n for n, i in items}
            ordered = sorted(keep, key=lambda i: (i["created_at"], pos[id(i)]))
        # keep is None: no root (a cycle) → data order, as for a legacy chat
    msgs = []
    for i in ordered:
        if i.get("type") != "message" or i["role"] == "system": continue
        same = [w for w in ordered if w["response_id"] == i["response_id"]]
        msgs.append(near_message(i, same))
    return {"sourceId": source_id, "title": title, "createdAt": created_at, "messages": msgs,
            "itemsSkipped": skipped, "mayBeIncomplete": may_be_incomplete}

def near_title(meta):
    t = meta.get("title") if isinstance(meta, dict) else None
    t = t.strip() if _str(t) else ""
    return None if t in ("", "New Conversation") else t

def near_legacy(meta):
    v = meta.get("imported_at") if isinstance(meta, dict) else None
    if isinstance(v, bool) or not isinstance(v, (int, float, str)): return False
    try: return math.isfinite(float(v))
    except ValueError: return False

def near_parse(elements, kind, file_bytes):
    """elements: [('element', bytes, depth) | ('broken',)]. Returns (chats, fileSkipped)."""
    if kind == "near-full":
        chats = []; skipped = 0
        for e in elements:
            if e[0] in ("broken", "over"): skipped += 1; continue
            _, raw, depth = e
            c = json.loads(raw)
            if not (isinstance(c, dict) and _str(c.get("id")) and isinstance(c.get("data"), list)): skipped += 1; continue
            meta = c.get("metadata") if isinstance(c.get("metadata"), dict) else {}
            created = c["created_at"] * 1000 if _int(c.get("created_at")) else None
            chats.append(near_chat(c["id"], near_title(meta), created, c["data"], near_legacy(meta)))
        return chats, skipped
    # one chat's items; the caps apply to the whole file
    broken = any(e[0] == "broken" for e in elements)
    whole = [e for e in elements if e[0] == "element"]
    depth = 1 + max((e[2] for e in whole), default=0)
    if file_bytes > MAX_ELEMENT_BYTES or depth > MAX_DEPTH or any(e[0] == "over" for e in elements): return [], 1
    data = [json.loads(e[1]) for e in whole]
    pre = [] ; ids = set()
    for i in data:
        if readable(i) and i["id"] not in ids: ids.add(i["id"]); pre.append(i)
    rids = {i["response_id"] for i in pre}
    root = next((i["response_id"] for i in pre if prev_of(i) is None or prev_of(i) not in rids), None)
    if root is None:
        root = pre[0]["response_id"] if pre else None
    if root is None:
        return [], len(data) + (1 if broken else 0) + 1
    incomplete = len(elements) >= 100 or broken
    chat = near_chat("chat:" + root, None, None, data, False, incomplete, 1 if broken else 0)
    return [chat], 0

# ── writer (source-neutral) ──────────────────────────────────────────────────────────────
PLACEHOLDER = {"image": "[image not imported]", "file": "[file not imported]"}

def placeholder_line(kind, name):
    base = PLACEHOLDER[kind]
    return base[:-1] + ": " + name + "]" if name else base

def host(u):
    # Case kept, as iOS URL.host and Android java.net.URI.host keep it (Python's .hostname lowercases).
    try: netloc = urlsplit(u).netloc
    except ValueError: return u
    h = netloc.rsplit("@", 1)[-1]
    h = h[1:h.index("]")] if h.startswith("[") and "]" in h else h.split(":", 1)[0]
    return h or u

MAX_IMAGES_PER_MESSAGE = 10
MAX_ENCODED = 20 * 1024 * 1024
MAX_PIXELS = 50_000_000
MAX_DIM = 16384

def scaled(w, h, cap):
    long_, short = max(w, h), min(w, h)
    if long_ <= cap: return w, h
    s = max(1, math.floor(short * cap / long_ + 0.5))
    return (cap, s) if w >= h else (s, cap)

def sniff(b):
    if b[:3] == b"\xff\xd8\xff": return "jpeg"
    if b[:8] == b"\x89PNG\r\n\x1a\n": return "png"
    if b[:6] in (b"GIF87a", b"GIF89a"): return "gif"
    return None

def jpeg_orientation(b):
    """The EXIF orientation tag, as ImageIntake's JPEGOrientation reads it; 1 when absent."""
    b = b[:256 * 1024]
    if len(b) <= 4 or b[0] != 0xFF or b[1] != 0xD8: return 1
    i = 2
    while i + 4 <= len(b):
        if b[i] != 0xFF: return 1
        m = b[i + 1]
        if m in (0xDA, 0xD9): return 1
        length = (b[i + 2] << 8) | b[i + 3]
        if length < 2: return 1
        if m == 0xE1 and i + 10 <= len(b) and b[i + 4:i + 10] == b"Exif\x00\x00":
            t = i + 10
            if t + 8 > len(b): return 1
            little = {b"II": True, b"MM": False}.get(bytes(b[t:t + 2]))
            if little is None: return 1
            def u16(k):
                if k < 0 or k + 1 >= len(b): return None
                return (b[k] | b[k + 1] << 8) if little else (b[k] << 8 | b[k + 1])
            def u32(k):
                hi, lo = (u16(k + 2), u16(k)) if little else (u16(k), u16(k + 2))
                return None if hi is None or lo is None else (hi << 16 | lo)
            ifd = u32(t + 4)
            if ifd is None or ifd < 8 or ifd >= 1 << 20: return 1
            n = u16(t + ifd)
            if n is None or n >= 512: return 1
            for e in range(n):
                tag = u16(t + ifd + 2 + e * 12)
                if tag is None: return 1
                if tag == 0x0112:
                    v = u16(t + ifd + 2 + e * 12 + 8)
                    return v if v in range(1, 9) else 1
            return 1
        i += 2 + length
    return 1

def ref_image(url):
    """ImageIntake.fromDataURL's outcome: {width, height, mime} or None (a placeholder)."""
    import base64, io
    if not url.startswith("data:") or "," not in url: return None
    header, payload = url[5:].split(",", 1)
    parts = header.lower().split(";")
    if len(parts) != 2 or parts[1] != "base64" or not parts[0].startswith("image/"): return None
    declared = {"image/jpeg": "jpeg", "image/jpg": "jpeg", "image/png": "png", "image/gif": "gif"}.get(parts[0])
    if declared is None: return None
    if len(payload.encode()) > MAX_ENCODED // 3 * 4 + 4: return None
    try: raw = base64.b64decode(payload, validate=False)
    except Exception: return None
    if not raw or len(raw) > MAX_ENCODED or sniff(raw) != declared: return None
    try:
        from PIL import Image
        Image.MAX_IMAGE_PIXELS = None
        im = Image.open(io.BytesIO(raw))
        w, h = im.size
        if w == 0 or h == 0 or w > MAX_DIM or h > MAX_DIM or w * h > MAX_PIXELS: return None
        im.seek(0); im.load()
        rgba = im.convert("RGBA")
        transparent = rgba.getchannel("A").getextrema()[0] < 255
    except Exception:
        return None
    o = jpeg_orientation(raw) if declared == "jpeg" else 1
    if o in (5, 6, 7, 8): w, h = h, w
    w, h = scaled(w, h, 2048)
    return {"width": w, "height": h, "mime": "image/png" if transparent else "image/jpeg"}

def write(source, chats, store):
    """store: dict key → thread. Returns totals; adds threads to store."""
    tot = {"chatsImported": 0, "messagesImported": 0, "chatsAlreadyHere": 0, "itemsSkipped": 0, "mayBeIncomplete": False,
           "imagesImported": 0, "imagesSkipped": 0}
    for c in chats:
        key = f"{source}:{c['sourceId']}"
        if key in store: tot["chatsAlreadyHere"] += 1; continue      # nothing read from it is counted
        tot["itemsSkipped"] += c["itemsSkipped"]
        tot["mayBeIncomplete"] |= c["mayBeIncomplete"]
        rows = []; last = 0; img_in = img_out = 0
        for m in c["messages"]:
            lines = []; images = []; idx = 0
            for p in m["parts"]:
                if p[0] == "placeholder" and p[1] == "image":
                    got = ref_image(p[3]) if idx < MAX_IMAGES_PER_MESSAGE and p[3] else None
                    if got:
                        images.append(dict(got, index=idx)); idx += 1; continue
                    img_out += 1; idx += 1
                lines.append(p[1] if p[0] == "text" else placeholder_line(p[1], p[2]))
            text = "\n\n".join(lines)
            if not text and not images: tot["itemsSkipped"] += 1; continue
            ts = m["createdAt"] if m["createdAt"] > last else last + 1; last = ts
            src = []; seen = set()
            for s in m["sources"]:
                if s["url"] in seen: continue
                seen.add(s["url"]); d = host(s["url"])
                src.append({"url": s["url"], "domain": d, "title": s["title"] or d, "snippet": ""})
            mkey = f"{key}:{m['sourceId']}"
            img_in += len(images)
            row = {"key": mkey, "role": m["role"], "text": text, "ms": ts, "sources": src}
            if images:
                row["images"] = [{"key": f"{mkey}#{i['index']}", "index": i["index"], "width": i["width"],
                                  "height": i["height"], "mime": i["mime"]} for i in images]
            rows.append(row)
        if not rows: tot["itemsSkipped"] += 1; continue
        store[key] = {"key": key, "title": c["title"], "updatedMs": rows[-1]["ms"], "messages": rows}
        tot["chatsImported"] += 1; tot["messagesImported"] += len(rows)
        tot["imagesImported"] += img_in; tot["imagesSkipped"] += img_out
    return tot

# ── one import ───────────────────────────────────────────────────────────────────────────
SOURCES = [("near", near_detect, near_parse)]

def import_file(raw, store):
    elements = list(scan(raw))
    if not elements:
        return {"chatsImported": 0, "messagesImported": 0, "chatsAlreadyHere": 0, "itemsSkipped": 0, "mayBeIncomplete": False,
                "imagesImported": 0, "imagesSkipped": 0}
    whole = [e for e in elements if e[0] == "element"]
    if not whole: raise Rejected(WRONG_FILE)          # nothing within the caps to detect by
    first = json.loads(whole[0][1])
    for source, detect, parse in SOURCES:
        kind = detect(first)
        if kind:
            chats, file_skipped = parse(elements, kind, len(raw))
            tot = write(source, chats, store)
            tot["itemsSkipped"] += file_skipped
            return tot
    raise Rejected(WRONG_FILE)

def import_path(path, store):
    with open(path, "rb") as f: return import_file(f.read(), store)

if __name__ == "__main__":
    args = sys.argv[1:]
    store_path = args[args.index("--store") + 1] if "--store" in args else None
    store = json.load(open(store_path)) if store_path else {}
    try: tot = import_path(args[0], store)
    except Rejected as e: print("REJECTED", e); sys.exit(0)
    if "--json" in args:
        print(json.dumps({"totals": tot, "threads": list(store.values())}, ensure_ascii=False, indent=1))
    else:
        for t in store.values():
            print(t["key"], repr(t["title"]), "msgs", len(t["messages"]), "updated", t["updatedMs"])
            for m in t["messages"]:
                print("   ", m["role"][0], m["ms"], repr(m["text"])[:90], [(s["domain"], s["title"]) for s in m["sources"]] or "")
        print(tot)
    if store_path: json.dump(store, open(store_path, "w"), ensure_ascii=False)
