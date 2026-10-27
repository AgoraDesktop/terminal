/*
 * AGTerminalSession.h — a shell on a pty, and the grid it writes into.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THE PROCESS AND THE SCREEN, TOGETHER, BECAUSE NEITHER IS USEFUL ALONE. `NSTask -setUsesPseudoTerminal:` gives the
 * child a real controlling terminal (its own session, `isatty` true, `TIOCSWINSZ` reaching it as `SIGWINCH`), and
 * the master end is an `NSFileHandle` whose readability handler fires on the run loop — so output arrives without a
 * thread and without polling.
 *
 * **THE END-OF-FILE FOOTGUN IS HANDLED HERE RATHER THAN LEFT TO BE DISCOVERED.** A pty master whose child has exited
 * is readable FOR EVER: the read fails with `EIO` instead of returning zero, so a level-triggered source left
 * installed spins a core. The handler uninstalls itself on the first empty read, which is what
 * `libagora-base/tests/nstask_pseudoterminal.m` records for the same reason.
 */
#ifndef AG_TERMINAL_SESSION_H
#define AG_TERMINAL_SESSION_H

#import <Foundation/Foundation.h>
#import "AGTerminalGrid.h"

@class AGTerminalSession;

@protocol AGTerminalSessionDelegate <NSObject>
@optional
/* The screen changed: a view marks itself for display. Delivered on the run loop's thread, which is the main one. */
- (void)terminalSessionDidProduceOutput:(AGTerminalSession *)session;
- (void)terminalSessionDidExit:(AGTerminalSession *)session;
@end

@interface AGTerminalSession : NSObject <AGTerminalGridDelegate>
{
	AGTerminalGrid *_grid;
	id <AGTerminalSessionDelegate> _delegate;	/* NOT RETAINED */
	id _task;					/* an NSTask; `id` so this header names no Foundation class */
	BOOL _running;
}

- (id)initWithColumns:(NSUInteger)columns rows:(NSUInteger)rows;

- (AGTerminalGrid *)grid;

/* `shellPath` may be nil for the environment's `$SHELL`, and `nil` again for `/bin/sh`. A LOGIN SHELL, because that
 * is what a terminal window is: the same startup files a person's account expects. */
- (BOOL)startWithShell:(NSString *)shellPath;
- (BOOL)isRunning;

- (void)write:(NSData *)data;
- (void)writeString:(NSString *)string;

/* The screen's size, in cells, and the pty's — one call so the two cannot disagree. The pty hears about it as
 * `SIGWINCH`, which is what makes `stty size`, `COLUMNS` and every full-screen program agree with the glass. */
- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows;

- (void)setDelegate:(id <AGTerminalSessionDelegate>)delegate;
- (id <AGTerminalSessionDelegate>)delegate;

@end

#endif /* AG_TERMINAL_SESSION_H */
