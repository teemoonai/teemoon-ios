# Builds the near import corpus under conformance/import/near/ and its manifest cases.json, whose
# expected results come from reference_import.py. Every app runs each case and compares.
#
#   python3 -I make_corpus.py <conformance/import/near>
#
# Small cases are committed as files under hostile/. Big ones (oversize, many chats) are not: cases.json
# gives a recipe that every app expands with plain string concatenation, plus the sha256 of the result,
# so both platforms prove they built the same bytes before importing them.
import copy, hashlib, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference_import as ref

OUT = sys.argv[1]
H = os.path.join(OUT, "hostile")
os.makedirs(H, exist_ok=True)
FULL = open(os.path.join(OUT, "near-export-v1.json"), "rb").read()
CHAT = open(os.path.join(OUT, "near-chat-export-v1.json"), "rb").read()
full = json.loads(FULL)
by_id = {c["id"]: c for c in full}

def dump(obj): return json.dumps(obj, ensure_ascii=False, indent=2).encode()
def compact(obj): return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
def sha(b): return hashlib.sha256(b).hexdigest()

def item(t, i, resp, ts, prev=None, nxt=(), **kw):
    d = {"type": t, "id": i, "response_id": resp, "next_response_ids": list(nxt), "created_at": ts, "status": "completed"}
    if prev is not None: d["previous_response_id"] = prev
    d.update(kw); return d
def say(i, resp, ts, role, text, prev=None, nxt=()):
    kind = "input_text" if role == "user" else "output_text"
    return item("message", i, resp, ts, prev, nxt, role=role, content=[{"type": kind, "text": text}])
def conv(cid, title, data, **meta):
    m = {"title": title}; m.update(meta)
    return {"id": cid, "created_at": 1761000000, "metadata": m, "data": data,
            "first_id": data[0]["id"] if data else "", "has_more": False,
            "last_id": data[-1]["id"] if data else "", "object": "list"}

def expected(raw, store=None, rerun=True):
    store = {} if store is None else store
    try: first = ref.import_file(raw, store)
    except ref.Rejected: return {"rejected": True}
    out = {"first": first}
    if rerun: out["second"] = ref.import_file(raw, copy.deepcopy(store))
    out["threads"] = [t["key"] for t in store.values()]
    return out, store

cases = []
def add_file(name, raw, covers, full_threads=True):
    open(os.path.join(H, name), "wb").write(raw)
    r = expected(raw)
    if isinstance(r, dict): entry = {"name": name, "file": "hostile/" + name, "sha256": sha(raw), "bytes": len(raw), "covers": covers, "expected": r}
    else:
        e, store = r
        if full_threads: e["threadsDetail"] = list(store.values())
        entry = {"name": name, "file": "hostile/" + name, "sha256": sha(raw), "bytes": len(raw), "covers": covers, "expected": e}
    cases.append(entry)

# ── malformed files ───────────────────────────────────────────────────────────────────────────
tie_at = FULL.index(b'"id": "conv_tie"')
add_file("truncated-full.json", FULL[:tie_at + 400],
         "cut off inside the third conversation: the two whole ones import, the cut one counts 1, no ']' needed")
add_file("truncated-first.json", FULL[:2000], "cut off inside the first element: the whole file is rejected")
add_file("truncated-chat.json", CHAT[:CHAT.index(b'"id":"msg_c3"') + 40],
         "a single-chat file cut off mid item: the whole items import, the cut one counts 1, mayBeIncomplete")
add_file("not-json.json", b"hello, this is not json", "not JSON: rejected")
add_file("empty-file.json", b"", "zero bytes: rejected")
add_file("object-top.json", dump({"conversations": full[:1]}), "an object at the top level: rejected")
add_file("number-first.json", b"[1, 2, 3]", "an array whose first element is a number: rejected")
add_file("empty-array.json", b"[]", "an empty array: a full export with nothing in it")
add_file("bom.json", b"\xef\xbb\xbf" + CHAT, "a UTF-8 byte order mark before the per-chat fixture: skipped, imports as the fixture")
add_file("trailing-garbage.json", CHAT + b"\n<html>oops</html>", "bytes after the closing ']' are ignored")
add_file("bad-separator.json", b"[" + compact(by_id["conv_tie"]) + b";" + compact(by_id["conv_prime"]) + b"]",
         "a ';' between elements: the first imports, the read ends there and counts 1")
add_file("invalid-utf8.json", b"[" + compact(by_id["conv_tie"]) + b"," + compact(by_id["conv_prime"]).replace(b"Name a prime", b"Name a \xff prime") + b"]",
         "invalid UTF-8 inside the second conversation: the first imports, the read ends and counts 1")
add_file("duplicate-conversation.json", dump([by_id["conv_tie"], by_id["conv_tie"]]),
         "the same conversation twice in one file: the second is already here")

# ── wrong types ───────────────────────────────────────────────────────────────────────────────
good_u = say("m_u", "r_1", 1761000000, "user", "A plain question.", prev="r_outside")
good_a = say("m_a", "r_1", 1761000001, "assistant", "A plain answer.", prev="r_outside")
wt_items = [
    good_u,
    dict(say("m_f", "r_1", 1761000002, "user", "float time"), created_at=1761000002.5),
    dict(say("m_s", "r_1", 1761000002, "user", "string time"), created_at="1761000002"),
    dict(say("m_b", "r_1", 1761000002, "user", "bool time"), created_at=True),
    dict(say("m_n", "r_1", 1761000002, "user", "number id"), id=7),
    dict(say("m_r", "r_1", 1761000002, "user", "null response"), response_id=None),
    dict(say("m_c", "r_1", 1761000002, "user", "x"), content="a string, not parts"),
    dict(say("m_o", "r_1", 1761000002, "user", "x"), role=7),
    "a string where an item belongs",
    None,
    item("message", "m_parts", "r_1", 1761000003, "r_outside", role="assistant", content=[
        42, None, "text", {"type": "output_text", "text": 99},
        {"type": "output_text", "text": "Parts survive.", "annotations": "not a list"},
        {"type": "output_text", "text": "Sources survive.", "annotations": [
            {"type": "url_citation", "url": 5, "title": "number url"},
            {"type": "url_citation", "url": "https://example.net/t", "title": 7},
            "not an annotation"]}]),
    item("web_search_call", "ws_bad", "r_1", 1761000003, "r_outside", action="not an object"),
    item("web_search_call", "ws_bad2", "r_1", 1761000003, "r_outside", action={"type": "search", "sources": "nope"}),
    good_a,
]
wrong = [
    conv("conv_wt_items", "Wrong-typed items", wt_items),
    dict(conv("conv_wt_prev", "Wrong-typed links", [
        dict(say("p_u", "r_p", 1761000100, "user", "Links of the wrong type."), previous_response_id=5, next_response_ids="r_q"),
        say("p_a", "r_p", 1761000101, "assistant", "Still imported."),
    ])),
    dict(conv("conv_wt_meta", "x", [say("t_u", "r_t", 1761000200, "user", "Metadata is a string.")]), metadata="not an object"),
    conv("conv_wt_title", 42, [say("n_u", "r_n", 1761000300, "user", "The title is a number.")]),
    conv("conv_wt_legacy", "imported_at is a bool", [
        say("l_u", "r_l1", 1761000400, "user", "First.", prev="r_none"),
        say("l_a", "r_l1", 1761000401, "assistant", "Kept: imported_at true is not a legacy marker.", prev="r_none"),
    ], imported_at=True),
    dict(conv("conv_wt_created", "created_at is a string", [say("c_u", "r_c", 1761000500, "user", "Conversation time is a string.")]), created_at="yesterday"),
    {"id": 7, "data": []},
    {"id": "conv_wt_data", "data": {"not": "a list"}},
    "a string where a conversation belongs",
]
add_file("wrong-types.json", dump(wrong), "wrong-typed fields at every level; each rule in section 3.1 and 4")

# ── links ─────────────────────────────────────────────────────────────────────────────────────
cycles = [
    conv("conv_cycle", "A loop with no root", [
        say("c_u1", "r_a", 1761001000, "user", "Loop question one.", prev="r_b"),
        say("c_a1", "r_a", 1761001001, "assistant", "Loop answer one.", prev="r_b"),
        say("c_u2", "r_b", 1761001002, "user", "Loop question two.", prev="r_a"),
        say("c_a2", "r_b", 1761001003, "assistant", "Loop answer two.", prev="r_a"),
    ]),
    conv("conv_self", "A response that is its own parent", [
        say("s_u", "r_s", 1761001100, "user", "Self question.", prev="r_s"),
        say("s_a", "r_s", 1761001101, "assistant", "Self answer.", prev="r_s"),
    ]),
    conv("conv_loop_below", "A loop under a real root", [
        say("b_u1", "r_1", 1761001200, "user", "Root question.", prev="r_gone", nxt=["r_2"]),
        say("b_a1", "r_1", 1761001201, "assistant", "Root answer.", prev="r_gone", nxt=["r_2"]),
        say("b_u2", "r_2", 1761001202, "user", "Second question.", prev="r_1", nxt=["r_3"]),
        say("b_a2", "r_2", 1761001203, "assistant", "Second answer.", prev="r_1", nxt=["r_3"]),
        say("b_u3", "r_3", 1761001204, "user", "Third question.", prev="r_2", nxt=["r_2", "r_1"]),
        say("b_a3", "r_3", 1761001205, "assistant", "Third answer.", prev="r_2", nxt=["r_2", "r_1"]),
    ]),
]
add_file("cycles.json", dump(cycles), "previous_response_id loops: no root → data order; a loop under a root is walked once")
no_last = copy.deepcopy(by_id["conv_prime"])
for k in ("first_id", "last_id", "has_more", "object"): no_last.pop(k)
add_file("missing-last-id.json", dump([no_last]), "no first_id/last_id/has_more/object: same result as conv_prime, last_id is never used")

parent_only = [conv("conv_parent_only", "A link to a response known only as a parent", [
    say("po_u1", "r1", 1761001300, "user", "Root question.", prev="r0", nxt=["r0x"]),
    say("po_a1", "r1", 1761001301, "assistant", "Root answer.", prev="r0", nxt=["r0x"]),
    say("po_u2", "r2", 1761001302, "user", "A question under a missing parent.", prev="r0x"),
    say("po_a2", "r2", 1761001303, "assistant", "An answer under a missing parent.", prev="r0x"),
])]
add_file("parent-only-link.json", dump(parent_only),
         "next_response_ids names a response with no items (only some item's parent): the walk never enters it, so the path is the root")

# ── depth and length ──────────────────────────────────────────────────────────────────────────
def nested(k):
    v = "deep"
    for _ in range(k): v = [v]
    return v
def deep_conv(cid, k): return conv(cid, "Deep " + cid, [say(cid + "_u", "r_" + cid, 1761002000, "user", "Nested metadata.")], extra=nested(k))
# element depth = 1 (conversation) + 1 (metadata) + k arrays
add_file("depth-64.json", dump([deep_conv("conv_d64", 62), by_id["conv_tie"]]), "a conversation nested exactly 64 deep: imported")
add_file("depth-65.json", dump([deep_conv("conv_d65", 63), by_id["conv_tie"]]), "a conversation nested 65 deep: skipped, counts 1; the next one imports")
# 65 deep with broken JSON inside: over the cap, so it is skipped unparsed and the read goes on
deep_broken = ('[' + compact(by_id["conv_tie"]).decode() + ',{"id":"conv_deep_broken","metadata":{"title":"x"},"data":[],"extra":'
               + "[" * 64 + "oops" + "]" * 64 + '},' + compact(by_id["conv_prime"]).decode() + ']').encode()
add_file("deep-and-broken.json", deep_broken,
         "an element over the depth cap that is also broken JSON: skipped unparsed, counts 1, the next one imports")
long_text = "Long message. " * 30000          # 420,000 characters
long_title = "T" * 100000
long_url = "https://example.com/" + "p" * 8000
add_file("long-strings.json", dump([conv("conv_long", long_title, [
    say("lg_u", "r_lg", 1761003000, "user", long_text, prev="r_x"),
    item("message", "lg_a", "r_lg", 1761003001, "r_x", role="assistant",
         content=[{"type": "output_text", "text": "Short answer.", "annotations": [{"type": "url_citation", "url": long_url, "title": "Long URL"}]}]),
])]), "a 420,000-character message, a 100,000-character title and an 8,000-character URL: stored whole", full_threads=False)

# ── images (IMAGES.md §2): one conversation per case, each user message carrying the image ─────────
import base64, io
from PIL import Image, ImageDraw
IMG = os.path.join(OUT, "images"); os.makedirs(IMG, exist_ok=True)
def quadrants(w, h, mode="RGB"):
    im = Image.new(mode, (w, h), (255, 255, 255) if mode == "RGB" else (255, 255, 255, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w // 2 - 1, h // 2 - 1], fill=(255, 0, 0)); d.rectangle([w // 2, 0, w - 1, h // 2 - 1], fill=(0, 255, 0))
    d.rectangle([0, h // 2, w // 2 - 1, h - 1], fill=(0, 0, 255))
    return im
def save(im, fmt, **kw):
    buf = io.BytesIO(); im.save(buf, fmt, **kw); return buf.getvalue()
def url(mime, raw): return f"data:{mime};base64," + base64.b64encode(raw).decode()
valid_jpeg = save(quadrants(300, 200), "JPEG", quality=90)
exif6 = Image.Exif(); exif6[0x0112] = 6
gps = Image.Exif(); gps[0x8825] = {1: "N", 2: (38.0, 42.0, 0.0), 3: "W", 4: (9.0, 8.0, 0.0)}; gps[0x010F] = "SecretCam"
transparent = Image.new("RGBA", (40, 40), (255, 0, 0, 128))
anim = [quadrants(50, 30).convert("P"), Image.new("P", (50, 30), 0)]
png_ok = save(quadrants(300, 200), "PNG")
bomb = bytearray(png_ok); bomb[16:24] = (100000).to_bytes(4, "big") * 2
image_cases = [
    ("img_jpeg", url("image/jpeg", valid_jpeg), "a valid JPEG"),
    ("img_png", url("image/png", png_ok), "a valid PNG"),
    ("img_gif", url("image/gif", save(quadrants(50, 30).convert("P"), "GIF")), "a valid GIF"),
    ("img_anim", url("image/gif", save(anim[0], "GIF", save_all=True, append_images=anim[1:], duration=100, loop=0)), "an animated GIF: its first frame"),
    ("img_alpha", url("image/png", save(transparent, "PNG")), "a transparent PNG stays PNG"),
    ("img_orient6", url("image/jpeg", save(quadrants(300, 200), "JPEG", quality=90, exif=exif6)), "EXIF orientation 6: width and height swap"),
    ("img_big", url("image/jpeg", save(quadrants(3000, 2000), "JPEG", quality=60)), "3000×2000: long side 2048, short side half up"),
    ("img_gps", url("image/jpeg", save(quadrants(64, 64), "JPEG", quality=90, exif=gps)), "a JPEG carrying GPS and a camera name"),
    ("img_truncated", url("image/jpeg", valid_jpeg[: len(valid_jpeg) // 2]), "a truncated JPEG: placeholder"),
    ("img_bomb", url("image/png", bytes(bomb)), "a PNG declaring 100,000 × 100,000: placeholder"),
    ("img_lying", url("image/jpeg", png_ok), "PNG bytes declared as JPEG: placeholder"),
    ("img_webp", url("image/webp", save(quadrants(32, 32), "WEBP")), "WebP is never decoded: placeholder"),
    ("img_svg", url("image/svg+xml", b"<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>"), "SVG with a script: placeholder"),
    ("img_html", "data:text/html;base64," + base64.b64encode(b"<h1>hi</h1>").decode(), "data:text/html: placeholder"),
    ("img_badb64", "data:image/png;base64,!!!not base64!!!", "invalid base64: placeholder"),
    ("img_http", "http://127.0.0.1:9/never-fetched.png", "an http URL is never fetched: placeholder"),
    # near.ai's cloud-api stores image_url as sent: a string or {"url": ...} (pm, 2026-11-06).
    ("img_object", {"url": url("image/jpeg", valid_jpeg)}, "image_url as an object {url}: a valid JPEG"),
    ("img_avif", url("image/avif", save(quadrants(32, 32), "AVIF")), "AVIF is never decoded: placeholder"),
    ("img_https", "https://127.0.0.1:9/never-fetched.png", "an https URL is never fetched: placeholder"),
]
convs = []
for n, (cid, image_url, covers) in enumerate(image_cases):
    convs.append(conv("conv_" + cid, covers, [
        item("message", cid + "_u", "r_" + cid, 1761100000 + n * 10, "r_root", role="user",
             content=[{"type": "input_text", "text": "case " + cid}, {"type": "input_image", "image_url": image_url}]),
        say(cid + "_a", "r_" + cid, 1761100001 + n * 10, "assistant", "noted", prev="r_root"),
    ]))
def many(n): return [{"type": "input_text", "text": f"{n} images"}] + [{"type": "input_image", "image_url": url("image/png", save(quadrants(8 + i, 8), "PNG"))} for i in range(n)]
convs.append(conv("conv_img_nine", "9 images in one message: all nine are kept", [
    item("message", "nine_u", "r_nine", 1761101000, "r_root", role="user", content=many(9)),
]))
convs.append(conv("conv_img_eleven", "11 images in one message: ten are kept, the 11th is a placeholder", [
    item("message", "eleven_u", "r_eleven", 1761101500, "r_root", role="user", content=many(11)),
]))
only = conv("conv_img_only", "a message that is only an image still imports", [
    item("message", "only_u", "r_only", 1761102000, "r_root", role="user", content=[{"type": "input_image", "image_url": url("image/png", png_ok)}]),
])
convs.append(only)
# The keys near.ai's own client puts on a part (id, name) and a detail level: read past.
convs.append(conv("conv_img_detail", "input_image with detail and unknown keys: a valid PNG", [
    item("message", "detail_u", "r_detail", 1761103000, "r_root", role="user", content=[
        {"type": "input_text", "text": "case img_detail"},
        {"type": "input_image", "image_url": url("image/png", png_ok), "detail": "auto", "id": "img_7f3", "name": "photo.png",
         "x_unknown": {"nested": True}}]),
]))
# A file or a recording near.ai stored by id only: marked where it was, never fetched.
convs.append(conv("conv_img_files", "an image beside a file and a recording kept by id: one image, two markers", [
    item("message", "files_u", "r_files", 1761104000, "r_root", role="user", content=[
        {"type": "input_text", "text": "case img_files"},
        {"type": "input_image", "image_url": url("image/png", png_ok)},
        {"type": "input_file", "file_id": "file-0b1c2d3e4f"},
        {"type": "input_audio", "file_id": "file-5a6b7c8d9e"}]),
]))
add_file("images.json", dump(convs), "every image case of IMAGES.md §2, one conversation each")
os.replace(os.path.join(H, "images.json"), os.path.join(IMG, "images.json"))
cases[-1]["file"] = "images/images.json"

# ── generated (not committed): recipe + sha ───────────────────────────────────────────────────
def expand(recipe):
    out = []
    for part in recipe:
        if isinstance(part, str): out.append(part)
        elif "repeat" in part: out.append(part["repeat"] * part["count"])
        else: out.append(part.get("joiner", "").join(part["each"].replace("{i}", str(i)) for i in range(part["count"])))
    return "".join(out).encode()

tie_compact = compact(by_id["conv_tie"]).decode()
big_n = 64 * 1024 * 1024 + 1
oversize = [
    '[{"id":"conv_big","created_at":1761004000,"metadata":{"title":"Too big"},"data":[{"type":"message","id":"big_u","response_id":"r_big","created_at":1761004000,"status":"completed","role":"user","content":[{"type":"input_text","text":"',
    {"repeat": "a", "count": big_n},
    '"}]}]},', tie_compact, "]",
]
many_each = ('{"id":"conv_many_{i}","created_at":1761005000,"metadata":{"title":"Chat {i}"},"data":['
             '{"type":"message","id":"u","response_id":"r_{i}","created_at":1761005000,"status":"completed","role":"user","content":[{"type":"input_text","text":"Question {i}?"}]},'
             '{"type":"message","id":"a","response_id":"r_{i}","created_at":1761005001,"status":"completed","role":"assistant","content":[{"type":"output_text","text":"Answer {i}."}]}]}')
many = ["[", {"each": many_each, "count": 5000, "joiner": ","}, "]"]
chat100_each = ('{"type":"message","id":"q{i}","response_id":"r{i}","created_at":1761006000,"status":"completed","role":"user","content":[{"type":"input_text","text":"Turn {i}."}]}')
image_oversize = ['[{"id":"conv_img_oversize","created_at":1761103000,"metadata":{"title":"21 MiB image"},"data":[{"type":"message","id":"ov_u","response_id":"r_ov","created_at":1761103000,"status":"completed","role":"user","content":[{"type":"input_text","text":"case oversize"},{"type":"input_image","image_url":"data:image/jpeg;base64,/9j/',
                  {"repeat": "A", "count": 28 * 1024 * 1024}, '"}]}]}]']
# ~10 MB, near near.ai's upload cap and under ours: a real file size, not just big dimensions. A valid JPEG
# padded with comment segments right after SOI. Each segment is 65,535 bytes (a multiple of 3) and starts on
# a 3-byte boundary, so its base64 repeats exactly and the recipe stays plain concatenation.
pad_seg = b"\xff\xfe" + (65533).to_bytes(2, "big") + b"teemoon" * (65531 // 7) + b"t" * (65531 % 7)
assert len(pad_seg) == 65535 and len(pad_seg) % 3 == 0
head = valid_jpeg[:2] + b"\xff\xfe\x00\x02"          # SOI + an empty comment: 6 bytes, 3-aligned
pad_count = 146
image_10mb = ['[{"id":"conv_img_10mb","created_at":1761105000,"metadata":{"title":"a ~10 MB JPEG data URL (300×200, comment-padded): imports"},"data":[{"type":"message","id":"tenmb_u","response_id":"r_10mb","created_at":1761105000,"status":"completed","role":"user","content":[{"type":"input_text","text":"case img_10mb"},{"type":"input_image","image_url":"data:image/jpeg;base64,'
              + base64.b64encode(head).decode(),
              {"repeat": base64.b64encode(pad_seg).decode(), "count": pad_count},
              base64.b64encode(valid_jpeg[2:]).decode() + '"}]}]}]']
generated = [
    ("image-10mb", image_10mb, f"a {6 + pad_count * 65535 + len(valid_jpeg) - 2}-byte JPEG (comment-padded) as a data URL: near.ai's 10 MB cap, under ours; imports"),
    ("image-oversize", image_oversize, "a 21 MiB image: placeholder before any decode; the text imports"),
    ("oversize", oversize, "a conversation over 64 MiB: skipped, counts 1; the next one imports"),
    ("many-chats", many, "5,000 conversations in one file (about 2.7 MB): every one imports; memory stays flat"),
]
for name, recipe, covers in generated:
    raw = expand(recipe)
    r = expected(raw, rerun=(name != "oversize"))
    e = r[0] if isinstance(r, tuple) else r
    if name == "many-chats": e["threads"] = len(e["threads"])
    cases.append({"name": name, "recipe": recipe, "sha256": sha(raw), "bytes": len(raw), "covers": covers, "expected": e})

# ── the two fixtures, and the cases draft 7 built from them ─────────────────────────────────
D = os.path.join(OUT, "derived"); os.makedirs(D, exist_ok=True)
def add_main(name, raw, covers):
    e, store = expected(raw); e["threadsDetail"] = list(store.values())
    cases.insert(0, {"name": name, "file": name, "sha256": sha(raw), "bytes": len(raw), "covers": covers, "expected": e})
add_main("near-chat-export-v1.json", CHAT, "the per-chat Export chat (.json) file; section 7")
SAMPLE = open(os.path.join(OUT, "sample", "near-export-sample.json"), "rb").read()
e_s, st_s = expected(SAMPLE); e_s["threadsDetail"] = list(st_s.values())
cases.append({"name": "near-export-sample.json", "file": "sample/near-export-sample.json", "sha256": sha(SAMPLE),
              "bytes": len(SAMPLE), "covers": "test 10: pm's readable sample on the real export's structure (invented text, example.* links; the maintainer OK'd committing it 2026-10-25)",
              "expected": e_s})
add_main("near-export-v1.json", FULL, "the full export; section 7")
chat_items = json.loads(CHAT)
def add_derived(name, raw, covers):
    open(os.path.join(D, name), "wb").write(raw)
    e, store = expected(raw); e["threadsDetail"] = list(store.values())
    cases.append({"name": name, "file": "derived/" + name, "sha256": sha(raw), "bytes": len(raw), "covers": covers, "expected": e})
add_derived("prime-as-chat-file.json", compact(by_id["conv_prime"]["data"]),
            "conv_prime's data as a per-chat file: thread near:chat:resp_p1, a second thread by design when imported after the full export")
turns = []
for t in range(50):
    turns.append(say(f"q{t}", f"r{t}", 1761007000 + 2 * t, "user", f"Turn {t}?", prev=f"r{t-1}" if t else "r_none"))
    turns.append(say(f"a{t}", f"r{t}", 1761007001 + 2 * t, "assistant", f"Reply {t}.", prev=f"r{t-1}" if t else "r_none"))
add_derived("chat-100.json", compact(turns), "a per-chat file of exactly 100 elements: mayBeIncomplete")
add_derived("chat-99.json", compact(turns[:99]), "99 elements: mayBeIncomplete false")
add_derived("mixed-full-first.json", dump([by_id["conv_lisbon"], chat_items[0]]), "a full export with a stray item: the item counts 1")
add_derived("mixed-items-first.json", compact(chat_items + [by_id["conv_tie"]]), "a per-chat file with a stray conversation: it counts 1")
no_resp = copy.deepcopy(chat_items); no_resp[0].pop("response_id")
add_derived("chat-first-item-no-response-id.json", compact(no_resp), "the first item has no response_id: it counts 1, the root is still resp_c1")
store2 = {}; ref.import_file(FULL, store2)
second = ref.import_file(compact(by_id["conv_prime"]["data"]), store2)
cases.append({"name": "same-chat-twice", "steps": ["import near-export-v1.json", "import derived/prime-as-chat-file.json"],
              "covers": "the same chat from the full export and its per-chat file: two threads by design",
              "expected": {"second": second, "threads": sorted(k for k in store2 if "prime" in k or "resp_p1" in k)}})

# ── sequences against the main fixture ────────────────────────────────────────────────────────
store = {}; ref.import_file(FULL, store)
before = copy.deepcopy(store["near:conv_prime"])
del store["near:conv_prime"]
again = ref.import_file(FULL, store)
cases.append({"name": "deleted-chat-returns", "steps": ["import near-export-v1.json", "delete the thread near:conv_prime",
              "import near-export-v1.json again"], "covers": "the maintainer 2026-10-25: a chat the user deleted comes back on re-import, with the same keys",
              "expected": {"third": again, "restoredThreadIdenticalToFirstImport": store["near:conv_prime"] == before}})

manifest = {"source": "near", "rule": "docs/IMPORT_NEAR.md section 7", "cases": cases}
open(os.path.join(OUT, "cases.json"), "w").write(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")
for c in cases:
    e = c["expected"]
    print(f'{c["name"]:28s}', "REJECTED" if e.get("rejected") else {k: v for k, v in (e.get("first") or e.get("third") or e.get("second")).items()})
