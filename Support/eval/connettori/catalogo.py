#!/usr/bin/env python3
"""«Demo OS»: servizio «a catalogo» con dati inventati, come i gestionali che espongono pochi strumenti generici
(cerca lo strumento interno, leggine lo schema, eseguilo). Solo per i banchi di prova."""
import datetime, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from mcp_base import serve

today = datetime.date.today()
def day(offset): return (today + datetime.timedelta(days=offset)).isoformat()

INVOICES = [
    {"number": "2026-041", "client": "Rossi Arredamenti", "amount_eur": 3200, "due": day(-12), "status": "overdue"},
    {"number": "2026-044", "client": "Verde Bio", "amount_eur": 850, "due": day(-3), "status": "overdue"},
    {"number": "2026-047", "client": "Bianchi Bike", "amount_eur": 1900, "due": day(15), "status": "unpaid"},
    {"number": "2026-039", "client": "Northwind Coffee", "amount_eur": 4100, "due": day(-30), "status": "paid"},
]
PROJECTS = [
    {"name": "Nuovo sito e-commerce", "client": "Rossi Arredamenti", "state": "active", "progress_percent": 60, "deadline": day(20)},
    {"name": "Rebranding 2027", "client": "Northwind Coffee", "state": "active", "progress_percent": 15, "deadline": day(75)},
    {"name": "Campagna social autunno", "client": "Bianchi Bike", "state": "closed", "progress_percent": 100, "deadline": day(-5)},
]
INTERNAL = {
    "invoices_list": {"description": "List invoices with number, client, amount and due date. Filter status: paid, unpaid or overdue.",
                      "write": False,
                      "inputSchema": {"type": "object", "properties": {"status": {"type": "string", "enum": ["paid", "unpaid", "overdue"]},
                                                                      "client": {"type": "string"}}}},
    "projects_list": {"description": "List projects with client, progress and deadline. Filter state: active or closed.",
                      "write": False,
                      "inputSchema": {"type": "object", "properties": {"state": {"type": "string", "enum": ["active", "closed"]}}}},
    "quote_create": {"description": "Create a quote (estimate) for a client with amount and description.",
                     "write": True,
                     "inputSchema": {"type": "object", "properties": {"client": {"type": "string"}, "amount_eur": {"type": "number"},
                                                                     "description": {"type": "string"}}, "required": ["client", "description"]}},
}

def stems(text):
    return {w[:5] for w in text.lower().replace(",", " ").replace(".", " ").replace(":", " ").split() if len(w) > 3}

def search_tools(args):
    query = stems(str(args.get("query", "")))
    if not query:
        raise ValueError("query is required: a few English keywords, e.g. 'invoices overdue'")
    found = []
    for name, spec in INTERNAL.items():
        score = len(query & stems(name.replace("_", " ") + " " + spec["description"]))
        if score:
            found.append((score, {"name": name, "description": spec["description"], "kind": "write" if spec["write"] else "read"}))
    found.sort(key=lambda item: -item[0])
    return {"tools": [item for _, item in found[:3]]}

def get_tool_schema(args):
    name = args.get("tool_name")
    if name not in INTERNAL:
        raise ValueError("unknown tool_name: use search_tools to find it (e.g. invoices_list)")
    spec = INTERNAL[name]
    return {"name": name, "description": spec["description"], "inputSchema": spec["inputSchema"]}

def check_arguments(name, arguments):
    for key, value in arguments.items():
        prop = INTERNAL[name]["inputSchema"]["properties"].get(key)
        if prop is None:
            raise ValueError("unknown argument '%s' for %s" % (key, name))
        if "enum" in prop and value not in prop["enum"]:
            raise ValueError("%s must be one of: %s" % (key, ", ".join(prop["enum"])))

def execute_read_tool(args):
    name, arguments = args.get("tool_name"), args.get("arguments") or {}
    if isinstance(arguments, str):
        import json
        try:
            arguments = json.loads(arguments) if arguments.strip() else {}
        except ValueError:
            raise ValueError("arguments must be a JSON object")
    if name not in INTERNAL:
        raise ValueError("unknown tool_name: use search_tools first")
    if INTERNAL[name]["write"]:
        raise ValueError("%s changes data: use execute_write_tool" % name)
    check_arguments(name, arguments)
    if name == "invoices_list":
        rows = [i for i in INVOICES if (not arguments.get("status") or i["status"] == arguments["status"])
                and (not arguments.get("client") or arguments["client"].lower() in i["client"].lower())]
        return {"invoices": rows, "total_eur": sum(i["amount_eur"] for i in rows)}
    rows = [p for p in PROJECTS if not arguments.get("state") or p["state"] == arguments["state"]]
    return {"projects": rows}

def execute_write_tool(args):
    return {"ok": True, "tool": args.get("tool_name"), "arguments": args.get("arguments")}

def whoami(args):
    return {"user": "demo@example.com", "agency": "Demo Agency"}

TOOLS = [
    {"name": "search_tools", "description": "Search the internal tools of Demo OS by keywords (English). Returns tool names and descriptions.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "English keywords"}}, "required": ["query"]},
     "annotations": {"readOnlyHint": True}},
    {"name": "get_tool_schema", "description": "Get the input schema of an internal tool found with search_tools.",
     "inputSchema": {"type": "object", "properties": {"tool_name": {"type": "string"}}, "required": ["tool_name"]},
     "annotations": {"readOnlyHint": True}},
    {"name": "execute_read_tool", "description": "Run an internal read-only tool with its arguments.",
     "inputSchema": {"type": "object", "properties": {"tool_name": {"type": "string"}, "arguments": {"type": "object"}}, "required": ["tool_name"]},
     "annotations": {"readOnlyHint": True}},
    {"name": "execute_write_tool", "description": "Run an internal tool that creates or changes data.",
     "inputSchema": {"type": "object", "properties": {"tool_name": {"type": "string"}, "arguments": {"type": "object"}}, "required": ["tool_name"]},
     "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "whoami", "description": "The signed-in user and agency.",
     "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": True}},
]

serve("Demo OS", TOOLS, {"search_tools": search_tools, "get_tool_schema": get_tool_schema, "execute_read_tool": execute_read_tool,
                         "execute_write_tool": execute_write_tool, "whoami": whoami},
      instructions="Demo OS is a catalog server: find the internal tool with search_tools, read its schema with get_tool_schema, then run it.")
