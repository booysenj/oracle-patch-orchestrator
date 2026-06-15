# Architecture

This repository contains an Oracle GI and Database Out-of-Place Patching Orchestrator.

## Components

Frontend
Backend
Agent

## Target Architecture

Frontend
    ↓
Backend API
    ↓
Job Queue
    ↓
Agent
    ↓
Oracle Host

## Design Principle

Backend orchestrates.

Agent executes.
