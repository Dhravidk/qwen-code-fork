"""Lightweight MCP server exposing ETG and graph walkers."""

__all__ = [
    "JaseciMcpServer",
    "main",
]

__version__ = "0.1.0"

from .server import JaseciMcpServer, main
