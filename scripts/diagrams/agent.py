"""The agent: how one chat message is answered, and what each route reaches.

check-docs.py [diagrams] fails when a node in chatbot-backend's graph (`add_node`) or a route
(`Route`) is not drawn here. The per-node reference is chatbot-backend/docs/graph.md.
"""
import draw
from draw import ACCENT, E, FRAME, _id, arrow, frame, mid, text

STYLE = "clean"
W, H = 2340, 1420
MUTED = "#868e96"


def box(*a, **k):
    return draw.box(*a, align="left", **k)


def lane(y, h, name, example):
    frame(690, y, 920, h, f'{name}   ·   e.g. "{example}"', FRAME["ns"], size=16)


def spoke(y, title, body, res, chain=False):
    """A spoke node, what it reads (directly, or the second through the first when `chain`),
    and its path on to the answer below them."""
    s = box(720, y + 50, 420, 190, title, body, owner="chatbot-backend", tsize=19, bsize=14.5)
    ry = y + 50
    for rt, rb, owner, h in res:
        r = box(1180, ry, 400, h, rt, rb, owner=owner, drum=owner not in ("metrics-gateway",
                "chatbot-backend"), tsize=17, bsize=14)
        if chain and ry > y + 50:
            arrow([mid(prev, "b"), mid(r, "t")])
        else:
            arrow([(1140, ry + h / 2), (1180, ry + h / 2)], dashed=True)
        prev, ry = r, ry + h + 15
    arrow([(650, y + 145), (720, y + 145)])
    arrow([mid(s, "b"), (930, y + 266), (1640, y + 266)])


def scene():
    text(40, 28, "How the chatbot answers a message", 34, bold=True)
    text(40, 80, "One LangGraph run per message. A coordinator picks exactly one route; that route "
                 "puts what it found in front of the model; the model answers and cites it. "
                 "The examples are real questions from chatbot-eval.", 17, color=MUTED)

    # In -------------------------------------------------------------------------------------
    you = box(40, 520, 250, 120, "You ask", "in a chat, in the browser\nPOST /v1/threads/{id}/\n"
              "messages", owner="frontend", bsize=14)
    prep = box(40, 690, 250, 180, "Before the graph", "checks your session\nloads this chat's "
               "last\n20 messages\nscopes document search\nto your account", owner="chatbot-backend",
               bsize=14)
    arrow([mid(you, "b"), mid(prep, "t")])

    # The graph ------------------------------------------------------------------------------
    frame(320, 140, 1640, 1170, "LangGraph   ·   chatbot-backend/src/app/graph/builder.py",
          FRAME["eks"], size=18)
    coord = box(350, 200, 300, 1080, "coordinate",
                "picks ONE route per message,\nreading only the last one\n\n"
                "on dev: rules, no model call\n\n1. a CALL-... id, or words like\n"
                "    call, caller, transcript\n    -> calls\n\n2. the metrics index finds a\n"
                "    metric or saved query\n    -> metrics\n\n3. enough words match your\n"
                "    documents' names and\n    summaries -> documents\n\n4. otherwise -> general\n\n"
                "the route is saved on the\nreply, and tags its trace", owner="chatbot-backend",
                tsize=20, bsize=15)
    arrow([mid(prep, "r"), (350, mid(prep, "r")[1])])

    lane(200, 150, "general", "Good morning. How are you today?")
    text(720, 252, "nothing to fetch: straight to the answer", 15, color=MUTED)
    arrow([(650, 300), (1640, 300)])

    lane(380, 285, "documents", "What quorum does the Quillhaven Charter require to open a sitting?")
    spoke(380, "retrieve", "searches YOUR documents only:\nby keywords and by meaning\n"
          "(BM25 + vectors, half each)\nkeeps what clears a score floor\nnumbers the extracts "
          "[1], [2]...,\none number per document",
          [("OpenSearch · kb-chunks", "your uploads, chunked and\nembedded when you upload",
            "third-party image", 90),
           ("embedding model", "bge-small, inside the backend:\nthe question, as a vector",
            "chatbot-backend", 90)])

    lane(690, 285, "calls", "Which cancellations calls in the last 3 days mentioned the Isle of "
         "Varrow, and what was offered?")
    spoke(690, "search_calls", "a CALL-... id -> that call\nelse filters from the words:\n"
          "queue, agent, dates, outcome\nthen a search, or the most recent\nat most 4 calls, "
          "one extract\neach, cited [1]...[4]",
          [("OpenSearch · calls-chunks", "transcripts, chunked and embedded\nby the call-worker, "
            "from SQS", "third-party image", 90),
           ("PostgreSQL · calls", "one row per call: queue,\nagent, time, outcome", "AWS managed",
            90)])

    lane(1000, 285, "metrics", "What was GMV in SP in 2017?")
    spoke(1000, "query_metrics", "no model, deterministic:\nfind the metric the question names,"
          "\nits filters (SP, RJ...) and window\nrun ONE governed query\nnothing fits -> it says so"
          "\nno SQL is ever written here",
          [("metrics-gateway · MCP", "6 tools: search, describe,\nvalues, query, saved query",
            "metrics-gateway", 90),
           ("MetricFlow -> Trino -> lake", "numbers from the definitions\nanalytics-dbt released",
            "third-party image", 90)], chain=True)

    ans = box(1640, 200, 290, 770, "answer",
              "create_agent: the model reads\nthe conversation and what the\nroute added, then "
              "writes the\nreply, citing [1], [2]...\n\nClaude Haiku 4.5\non Amazon Bedrock\n\n"
              "tools: none\n\nnothing found -> it says so;\nit cannot cite an extract\nit was "
              "not given", owner="chatbot-backend", tsize=20, bsize=15)
    ansm = box(1640, 1000, 290, 280, "answer_metrics",
               "the same agent, plus the\ngateway's 6 tools: it may\nsearch, describe and run\n"
               "more governed queries;\nevery run is cited with its\ndefinition and release",
               owner="chatbot-backend", tsize=20, bsize=15)

    # Out ------------------------------------------------------------------------------------
    out = box(1990, 520, 310, 170, "Saved and sent back", "the reply, its route and its\n"
              "citations are saved on the\nmessage (PostgreSQL), then\nreturned to the browser",
              owner="chatbot-backend", bsize=14)
    trace = box(1990, 730, 310, 130, "Traced", "the whole turn is one trace\nin Phoenix, tagged "
                "with\nits route", owner="third-party image", bsize=14)
    arrow([mid(ans, "r", (600 - 200) / 770), (1990, 600)])
    arrow([mid(ansm, "r", .5), (1965, 1140), (1965, 660), (1990, 660)])

    # Legend ---------------------------------------------------------------------------------
    text(40, 1340, "Colour = owning repo", 16, bold=True)
    lx = 230
    for name in ("frontend", "chatbot-backend", "metrics-gateway", "third-party image",
                 "AWS managed"):
        E.append(dict(kind="rect", id=_id("key"), x=lx, y=1342, w=16, h=16, fill=ACCENT[name],
                      dashed=False, stroke=ACCENT[name], sw=1.5))
        text(lx + 24, 1340, name, 15)
        lx += 60 + len(name) * 8.5
    text(40, 1374, "Per-node detail: chatbot-backend/docs/graph.md · why it has this shape: "
                   "chatbot-backend docs/adr/0007, 0014, 0016", 15, color=MUTED)
