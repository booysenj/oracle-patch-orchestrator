# Oracle Patch Orchestrator Roadmap

## Vision

Enterprise Oracle GI and Database Out-of-Place Patching Platform

## Current State

- React Frontend
- Node.js Backend
- SQLite Database
- Python Agent
- Partial SSH Execution

## Target State

- React Frontend
- Node.js Backend
- Python Agent
- Agent Driven Execution
- REST API Communication
- WebSocket Status Updates
- Centralized Inventory
- Job Orchestration Engine
- No SSH Execution

## Principles

Backend orchestrates.

Agent executes.

All Oracle operations run locally on the managed host through the agent.

The backend never directly logs into managed hosts.
