# Builds conformance/import/near/near-export-v1.json (and, with a second path, near-chat-export-v1.json) by hand from near's types (private-chat b5c5a97).
# Synthetic text and ids only; nothing from any real export.
import json,sys
M="zai-org/GLM-5.3-Flash"
AUTHOR={"author_id":"user_0001","author_name":"Sample Person"}
def base(t,i,resp,ts,prev,nxt):
    d={"type":t,"id":i,"response_id":resp,"next_response_ids":list(nxt),"created_at":ts,"status":"completed","model":M}
    if prev is not None: d["previous_response_id"]=prev
    return d
def user(i,resp,ts,parts,prev,nxt=()):
    d=base("message",i,resp,ts,prev,nxt); d.update(role="user",content=parts,metadata=dict(AUTHOR)); return d
def bot(i,resp,ts,parts,prev,nxt=(),status="completed"):
    d=base("message",i,resp,ts,prev,nxt); d.update(role="assistant",content=parts,status=status); return d
def reasoning(i,resp,ts,prev,nxt=()):
    d=base("reasoning",i,resp,ts,prev,nxt); d.update(content="Thinking about the request.",summary=""); return d
def search(i,resp,ts,prev,query,nxt=(),sources=None):
    d=base("web_search_call",i,resp,ts,prev,nxt); d["action"]={"type":"search","query":query}
    if sources is not None: d["action"]["sources"]=[{"type":"url","url":u} for u in sources]
    return d
def tin(t): return {"type":"input_text","text":t}
def tout(t,ann=()): return {"type":"output_text","text":t,"annotations":[{"type":"url_citation","url":u,"title":ti,"start_index":0,"end_index":len(t)} for u,ti in ann]}
def conv(cid,ts,meta,data):
    return {"id":cid,"created_at":ts,"metadata":meta,"data":data,
            "first_id":data[0]["id"] if data else "","has_more":False,"last_id":data[-1]["id"] if data else "","object":"list"}
V="https://www.visitlisboa.com/en/itineraries"; W="https://en.wikipedia.org/wiki/Bel%C3%A9m_Tower"; T="https://www.timeout.com/lisbon"
lisbon=conv("conv_lisbon",1760000000,{"title":"Two days in Lisbon","pinned_at":"2026-09-01T10:00:00Z"},[
 user("msg_u1","resp_l1",1760000000,[tin("What should I see in Lisbon in two days?")],"resp_outside_lisbon",["resp_l2"]),
 reasoning("rs_1","resp_l1",1760000001,"resp_outside_lisbon",["resp_l2"]),
 search("ws_1","resp_l1",1760000001,"resp_outside_lisbon","lisbon two day itinerary",["resp_l2"]),
 search("ws_2","resp_l1",1760000002,"resp_outside_lisbon","belem tower opening hours",["resp_l2"]),
 bot("msg_a1","resp_l1",1760000003,[tout("Day one: Alfama and the castle.",[(V,"Lisbon itineraries")]),
                                     tout("Day two: Belém — the tower and the pastéis.",[(W,"Belém Tower"),(V,"Lisbon itineraries")])],"resp_outside_lisbon",["resp_l2"]),
 user("msg_u2","resp_l2",1760000003,[tin("And where to eat?")],"resp_l1",["resp_l3"]),
 search("ws_3","resp_l2",1760000004,"resp_l1","lisbon food market",["resp_l3"],sources=[T]),
 bot("msg_a2","resp_l2",1760000010,[tout("Time Out Market for variety.")],"resp_l1",["resp_l3"]),
 user("msg_u3","resp_l3",1760000020,[tin("Anything open late?")],"resp_l2"),
 search("ws_4","resp_l3",1760000021,"resp_l2","lisbon late night food"),
 search("ws_5","resp_l3",1760000021,"resp_l2","bairro alto bars"),
 search("ws_6","resp_l3",1760000022,"resp_l2","lisbon open after midnight"),
 reasoning("rs_2","resp_l3",1760000023,"resp_l2"),
 bot("msg_a3","resp_l3",1760000025,[tout("Bairro Alto stays busy past midnight.")],"resp_l2"),
])
prime=conv("conv_prime",1760100000,{"title":""},[
 user("msg_u1","resp_p1",1760100000,[tin("Name a prime number.")],"resp_outside_prime",["resp_p2","resp_p3"]),
 bot("msg_a1","resp_p1",1760100001,[tout("7")],"resp_outside_prime",["resp_p2","resp_p3"]),
 user("msg_u2","resp_p2",1760100010,[tin("A bigger one?")],"resp_p1"),
 bot("msg_a2","resp_p2",1760100011,[tout("9")],"resp_p1"),
 user("msg_u3","resp_p3",1760100050,[tin("A bigger one?")],"resp_p1",["resp_p4"]),
 bot("msg_a3","resp_p3",1760100051,[tout("101")],"resp_p1",["resp_p4"]),
 user("msg_u4","resp_p4",1760100100,[tin("Bigger still?")],"resp_p3"),
 bot("msg_a4","resp_p4",1760100101,[tout("1009")],"resp_p3"),
])
tie=conv("conv_tie",1760150000,{"title":"New Conversation"},[
 user("msg_u1","resp_t1",1760150000,[tin("Pick a colour.")],"resp_outside_tie",["resp_t2","resp_t3"]),
 bot("msg_a1","resp_t1",1760150001,[tout("Blue.")],"resp_outside_tie",["resp_t2","resp_t3"]),
 user("msg_u2","resp_t2",1760150010,[tin("Another?")],"resp_t1"),
 bot("msg_a2","resp_t2",1760150011,[tout("Green.")],"resp_t1"),
 user("msg_u3","resp_t3",1760150020,[tin("Another?")],"resp_t1"),
 bot("msg_a3","resp_t3",1760150021,[tout("Red.")],"resp_t1"),
])
receipt=conv("conv_receipt",1760200000,{"title":"Receipt question","archived_at":"2026-09-10T08:00:00Z"},[
 user("msg_u1","resp_r1",1760200000,[tin("What's the total on this?"),
   {"type":"input_image","file_id":"file_img1","image_url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="},
   {"type":"input_file","file_id":"file_pdf1"},
   {"type":"input_audio","audio_file_id":"file_aud1"}],None),
 bot("msg_a1","resp_r1",1760200004,[tout("The total is €42.10.")],None),
])
damaged=conv("conv_damaged",1760300000,{"title":"Damaged items"},[
 user("msg_u1","resp_d1",1760300000,[tin("Hello")],"resp_outside_damaged",["resp_d2"]),
 {"type":"message","id":"msg_bad","response_id":"resp_d1","previous_response_id":"resp_outside_damaged","next_response_ids":["resp_d2"],"created_at":"yesterday","status":"completed","role":"assistant","content":"not an array","model":M},
 bot("msg_a1","resp_d1",1760300002,[tout("Hi there.")],"resp_outside_damaged",["resp_d2"]),
 bot("msg_a1","resp_d1",1760300003,[tout("A second item reusing msg_a1's id.")],"resp_outside_damaged",["resp_d2"]),
 user("msg_u2","resp_d2",1760300010,[tin("Still there?")],"resp_d1"),
 bot("msg_a2","resp_d2",1760300011,[],"resp_d1",status="failed"),
])
empty=conv("conv_empty",1760350000,{"title":"Nothing here"},[])
legacy=conv("conv_legacy",1760400000,{"title":"Imported notes","imported_at":"1760400000000"},[
 user("msg_u1","resp_g1",1760400000,[tin("First old question.")],"resp_g9"),
 bot("msg_a1","resp_g2",1760400000,[tout("First old answer.")],"resp_g9"),
 search("ws_1","resp_g2",1760400000,"resp_g9","old search",sources=["https://WWW.Example.com/x"]),
 user("msg_u2","resp_g4",1760400000,[tin("Second old question.")],"resp_g9"),
 bot("msg_a2","resp_g5",1760400001,[tout("Second old answer.")],"resp_g9"),
])
open(sys.argv[1],"w").write(json.dumps([lisbon,prime,tie,receipt,damaged,empty,legacy],indent=2,ensure_ascii=False))

# The per-chat "Export chat (.json)" file (DownloadDropdown.tsx): JSON.stringify(chatData.data), compact,
# a bare array of one conversation's items, no title or conversation id. Mid-chat regenerate included.
if len(sys.argv)>2:
    chat=[
     user("msg_c1","resp_c1",1760500000,[tin("Suggest a name for a cat.")],"resp_outside_chat",["resp_c2","resp_c3"]),
     reasoning("rs_c1","resp_c1",1760500001,"resp_outside_chat",["resp_c2","resp_c3"]),
     bot("msg_c2","resp_c1",1760500002,[tout("Miso.")],"resp_outside_chat",["resp_c2","resp_c3"]),
     user("msg_c3","resp_c2",1760500010,[tin("Something longer?")],"resp_c1"),
     bot("msg_c4","resp_c2",1760500011,[tout("Bartholomew.")],"resp_c1"),
     user("msg_c5","resp_c3",1760500020,[tin("Something longer?")],"resp_c1",["resp_c4"]),
     search("ws_c1","resp_c3",1760500021,"resp_c1","long cat names",["resp_c4"]),
     bot("msg_c6","resp_c3",1760500022,[tout("Sir Pounce-a-lot.",[("https://www.example.org/cat-names","Cat names")])],"resp_c1",["resp_c4"]),
     user("msg_c7","resp_c4",1760500030,[tin("Perfect, thanks.")],"resp_c3"),
     bot("msg_c8","resp_c4",1760500031,[tout("Enjoy the new name.")],"resp_c3"),
    ]
    open(sys.argv[2],"w").write(json.dumps(chat,ensure_ascii=False,separators=(",",":")))
