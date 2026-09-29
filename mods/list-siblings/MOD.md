# list-siblings

Adds a `list_siblings` tool: read the live fleet roster (every sibling's bare name + `-mcp`/`-watch` addresses) from the host `kubectl get services` via the docker-socket bridge. Call it before messaging or checking a sibling when unsure of the name.
