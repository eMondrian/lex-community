# eMondrian Lex — community edition

**Every definition knows its source.** Lex is a knowledge base filled only from source
documents: each class, property and definition arrives through a change request, is checked
against what the base already holds, approved by a person and applied with its provenance.
People work in the web UI; agents work through MCP.

## Install

You need Docker with Compose v2 (Linux or macOS; on Windows, inside WSL2).

```
git clone <this repository> lex
cd lex
./setup.sh
```

`setup.sh` checks Docker, writes your settings to `.env`, pulls the image, starts Lex and
prints where it is:

```
  Web:   http://192.168.1.20:8770/
  MCP:   http://192.168.1.20:8770/mcp
```

Point an MCP client (Claude Code, Claude Desktop, any Streamable HTTP client) at the MCP
address; open the web address in a browser.

## Options

```
./setup.sh --port 8800                       # another port
./setup.sh --git-remote <url>                # push every change of the base to a git remote
./setup.sh --domain lex.example.org          # https with a certificate (ports 80 and 443)
./setup.sh --interactive                     # be asked instead
./setup.sh --update                          # a new version: this repository, then the image
./setup.sh --help
```

Running `setup.sh` again is safe: it keeps `base/` and `.env`, and changes only the settings
you pass. Every setting is in `.env` (see `.env.example`); edit it and run `./setup.sh`.

## Your knowledge base

`base/` is your knowledge base, a git repository of its own: every change Lex makes is a
commit, so the history is the audit trail and any change can be looked at or undone. With
`--git-remote` each commit is also pushed there. Back it up as you back up any repository.

At its first start Lex makes an empty base in `base/`. A new version of Lex brings an older
base to its format by itself at start, one commit per step; if a step fails, it is rolled
back and Lex does not start.

## Day to day

```
docker compose logs -f lex      # the log
docker compose down             # stop
./setup.sh                      # start again
```

## Licences

This repository (the scripts and configuration) is under the MIT licence: see `LICENSE`.
The Lex image (`emondrian/lex`) is free to use, under its own licence; it may not be
decompiled, reverse engineered or resold.
