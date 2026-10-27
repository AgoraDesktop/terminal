#!/bin/bash
#
# Run the session probe WITHOUT a controlling terminal, because that is the shape the application is launched in.
#
# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: GPL-3.0-or-later
#
# **A TERMINAL APPLICATION IS STARTED BY A SESSION MANAGER, NOT FROM A SHELL, AND THAT DIFFERENCE HID A BUG FOR ONE
# RUN.** `NSTask` opened the pty's slave without `O_NOCTTY`; when the opener has no controlling terminal — a session
# manager, `setsid`, a service — that `open` gave the PARENT the pty as its controlling terminal, the child's
# `TIOCSCTTY` then had nothing to take (it does not steal), and the shell came up without job control. Every test run
# from an ordinary shell passed, because there the parent already had a terminal of its own. So the probe runs under
# `setsid` and the shape is the same every time.
set -u

BINARY="${1:?usage: run-terminal-session.sh BINARY}"
exec setsid -w "$BINARY"
