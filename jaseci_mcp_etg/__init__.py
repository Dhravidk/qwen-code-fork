"""Lightweight MCP server exposing ETG and graph walkers."""

__all__ = [
    "JaseciMcpServer",
    "main",
    "select_backend",
    "JacBackend",
    "StorageBackend",
]

__version__ = "0.2.0"

from .backend import JacBackend, StorageBackend, select_backend
from .server import JaseciMcpServer, main
