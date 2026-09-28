#!/usr/bin/env python3
"""«Demo CRM»: clienti e task inventati, con strumenti diretti (come molti connettori). Solo per i banchi di prova."""
import datetime, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from mcp_base import serve

today = datetime.date.today()
def day(offset): return (today + datetime.timedelta(days=offset)).isoformat()

CLIENTS = [
    {"id": "C-101", "name": "Rossi Arredamenti", "city": "Milano", "contact": "Giulia Rossi", "email": "giulia@rossi-arredamenti.example", "status": "active", "yearly_value_eur": 18400},
    {"id": "C-102", "name": "Bianchi Bike", "city": "Torino", "contact": "Marco Bianchi", "email": "marco@bianchibike.example", "status": "active", "yearly_value_eur": 9200},
    {"id": "C-103", "name": "Verde Bio", "city": "Bologna", "contact": "Sara Verdi", "email": "sara@verdebio.example", "status": "paused", "yearly_value_eur": 4100},
    {"id": "C-104", "name": "Northwind Coffee", "city": "London", "contact": "Emma Clarke", "email": "emma@northwind.example", "status": "active", "yearly_value_eur": 12900},
]
TASKS = [
    {"id": "T-1", "title": "Preparare il preventivo del nuovo sito", "client_id": "C-101", "due": day(1), "status": "open", "owner": "Luca"},
    {"id": "T-2", "title": "Rivedere la campagna social di ottobre", "client_id": "C-102", "due": day(2), "status": "open", "owner": "Anna"},
    {"id": "T-3", "title": "Inviare il report mensile", "client_id": "C-103", "due": day(-2), "status": "open", "owner": "Luca"},
    {"id": "T-4", "title": "Kick-off call for the rebranding", "client_id": "C-104", "due": day(9), "status": "open", "owner": "Anna"},
    {"id": "T-5", "title": "Aggiornare il listino prezzi", "client_id": "C-101", "due": day(-6), "status": "done", "owner": "Luca"},
]

def client_name(client_id):
    return next((c["name"] for c in CLIENTS if c["id"] == client_id), client_id)

def with_client(task):
    return dict(task, client=client_name(task["client_id"]))

def search(args):
    query = str(args.get("query", "")).lower().strip()
    if not query:
        raise ValueError("query is required")
    words = [w for w in query.split() if len(w) > 2]
    def hit(text): return any(w in text.lower() for w in words) if words else query in text.lower()
    clients = [c for c in CLIENTS if hit(c["name"] + " " + c["contact"] + " " + c["city"])]
    tasks = [with_client(t) for t in TASKS if hit(t["title"] + " " + client_name(t["client_id"]))]
    return {"clients": clients, "tasks": tasks}

def list_clients(args):
    status = args.get("status")
    if status and status not in ("active", "paused"):
        raise ValueError("status must be 'active' or 'paused'")
    return {"clients": [c for c in CLIENTS if not status or c["status"] == status]}

def get_client(args):
    client_id = args.get("client_id")
    client = next((c for c in CLIENTS if c["id"] == client_id), None)
    if not client:
        raise ValueError("client_id not found: use search or list_clients to find the id (e.g. C-101)")
    return dict(client, open_tasks=[t for t in TASKS if t["client_id"] == client_id and t["status"] == "open"])

def list_tasks(args):
    status = args.get("status", "open")
    if status not in ("open", "done"):
        raise ValueError("status must be 'open' or 'done'")
    tasks = [t for t in TASKS if t["status"] == status]
    within = args.get("due_within_days")
    if within is not None:
        try:
            limit = today + datetime.timedelta(days=int(within))
        except (TypeError, ValueError):
            raise ValueError("due_within_days must be a number of days")
        tasks = [t for t in tasks if datetime.date.fromisoformat(t["due"]) <= limit]
    if args.get("client_id"):
        tasks = [t for t in tasks if t["client_id"] == args["client_id"]]
    return {"today": today.isoformat(), "tasks": [with_client(t) for t in tasks]}

def create_task(args):
    return {"created": {"id": "T-99", "title": args.get("title"), "client_id": args.get("client_id"), "due": args.get("due")}}

TOOLS = [
    {"name": "search", "description": "Search clients and tasks by text (client name, contact person, city or task title).",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "Words to search"}}, "required": ["query"]},
     "annotations": {"readOnlyHint": True}},
    {"name": "list_clients", "description": "List the agency's clients with contact person, city and status. Optional status filter: 'active' or 'paused'.",
     "inputSchema": {"type": "object", "properties": {"status": {"type": "string", "description": "'active' or 'paused'"}}}},
    {"name": "get_client", "description": "Get one client's details and open tasks by client id (e.g. C-101).",
     "inputSchema": {"type": "object", "properties": {"client_id": {"type": "string", "description": "Client id, e.g. C-101"}}, "required": ["client_id"]}},
    {"name": "list_tasks", "description": "List tasks with due date, owner and client. status: 'open' (default) or 'done'. due_within_days: only tasks due within that many days from today (overdue ones included).",
     "inputSchema": {"type": "object", "properties": {"status": {"type": "string", "description": "'open' or 'done'"},
                                                     "due_within_days": {"type": "integer", "description": "Days from today"},
                                                     "client_id": {"type": "string", "description": "Only this client's tasks"}}}},
    {"name": "create_task", "description": "Create a new task for a client.",
     "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}, "client_id": {"type": "string"},
                                                     "due": {"type": "string", "description": "Due date YYYY-MM-DD"}}, "required": ["title"]},
     "annotations": {"readOnlyHint": False, "destructiveHint": False}},
]

serve("Demo CRM", TOOLS, {"search": search, "list_clients": list_clients, "get_client": get_client,
                          "list_tasks": list_tasks, "create_task": create_task})
