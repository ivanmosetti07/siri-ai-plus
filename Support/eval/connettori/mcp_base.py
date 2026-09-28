"""Server MCP minimo su stdin/stdout (JSON-RPC 2.0, un messaggio per riga) per i banchi di prova dei connettori.
Dati inventati: nessun servizio vero. Ogni chiamata viene scritta in CONNETTORI_REGISTRO (se impostato), per i controlli."""
import json, os, sys


def serve(name, tools, handlers, instructions=""):
    log_path = os.environ.get("CONNETTORI_REGISTRO")

    def send(message):
        sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method, ident = message.get("method"), message.get("id")
        if ident is None:
            continue  # notifiche
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": ident, "result": {
                "protocolVersion": message.get("params", {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}}, "serverInfo": {"name": name, "version": "1.0"}, "instructions": instructions}})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": ident, "result": {}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": ident, "result": {"tools": tools}})
        elif method == "tools/call":
            params = message.get("params", {})
            tool, arguments = params.get("name"), params.get("arguments") or {}
            if log_path:
                with open(log_path, "a") as log:
                    log.write(json.dumps({"server": name, "tool": tool, "arguments": arguments}, ensure_ascii=False) + "\n")
            try:
                handler = handlers[tool]
                result, error = handler(arguments), False
            except KeyError:
                result, error = "Unknown tool: %s" % tool, True
            except ValueError as problem:
                result, error = str(problem), True
            text = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
            send({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": text}], "isError": error}})
        else:
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "method not found"}})
