/*
 * terminal_session — a real shell on a real pty, read through the emulator, with no window anywhere.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THE OTHER HALF OF THE TERMINAL, AND THE HALF A PIXEL TEST CANNOT SEE. A shell is started the way the application
 * starts one (`NSTask -setUsesPseudoTerminal:`, a login shell, `TERM` set, the size before the launch), the run loop
 * is pumped so the master's readability handler can fire, and what the shell PRINTS is read back out of the grid —
 * so the chain under test is process → pty → emulator, with no compositor in it.
 *
 * **THE SIZE IS CHECKED TWICE, BEFORE AND AFTER A RESIZE**, because those are different kernel paths: a size set
 * before the launch is what the child's first `TIOCGWINSZ` answers, and a size set after it reaches the child as
 * `SIGWINCH`. `stty size` is asked for both, which is the only answer that comes from the kernel rather than from
 * this process's own bookkeeping.
 */
#import <Foundation/Foundation.h>

#import "AGTerminalGrid.h"
#import "AGTerminalSession.h"

#include <stdio.h>
#include <string.h>

static int checks;
static int failures;

static void check(int ok, const char *what)
{
	checks++;
	if (!ok) {
		failures++;
		printf("  [FAIL] %s\n", what);
	} else {
		printf("  [ok]   %s\n", what);
	}
}

/* THE SCREEN AS TEXT, which is what a person would read on the glass: the grid's cells in order, one row per line.
 * Empty cells are spaces because a terminal's blank IS a space, and the trailing spaces are dropped so a comparison is
 * about the ink. */
static NSString *screen_text(AGTerminalGrid *grid)
{
	const struct tsm_screen_cell *cells = [grid cellRows];
	NSMutableString *out = [NSMutableString string];
	NSUInteger columns = [grid columns];
	NSUInteger rows = [grid rows];
	NSUInteger row, column;

	if (cells == NULL) {
		return out;
	}
	for (row = 0; row < rows; row++) {
		NSMutableString *line = [NSMutableString string];

		for (column = 0; column < columns; column++) {
			uint32_t codepoint = cells[row * columns + column].ch;

			if (codepoint == 0 || codepoint == ' ') {
				[line appendString:@" "];
			} else if (codepoint < 0x10000) {
				unichar unit = (unichar)codepoint;

				[line appendString:[NSString stringWithCharacters:&unit length:1]];
			} else {
				uint32_t v = codepoint - 0x10000;
				unichar pair[2];

				pair[0] = (unichar)(0xD800 + (v >> 10));
				pair[1] = (unichar)(0xDC00 + (v & 0x3FF));
				[line appendString:[NSString stringWithCharacters:pair length:2]];
			}
		}
		[out appendString:line];
		if (row + 1 < rows) {
			[out appendString:@"\n"];
		}
	}
	return out;
}

/* RUN THE LOOP UNTIL THE SCREEN CONTAINS `wanted`, or the deadline passes. A fixed sleep would be a test that fails on
 * a loaded machine and passes on an idle one, which is the same as no test. */
static BOOL wait_for_text(AGTerminalGrid *grid, NSString *wanted, double seconds)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

	while ([deadline timeIntervalSinceNow] > 0.0) {
		if ([screen_text(grid) rangeOfString:wanted].location != NSNotFound) {
			return YES;
		}
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
	return NO;
}

@interface ExitWatcher : NSObject <AGTerminalSessionDelegate>
{
@public
	int exits;
}
@end

@implementation ExitWatcher
- (void)terminalSessionDidExit:(AGTerminalSession *)session
{
	(void)session;
	exits++;
}
@end

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	AGTerminalSession *session = [[AGTerminalSession alloc] initWithColumns:80 rows:24];
	AGTerminalGrid *grid;
	ExitWatcher *watcher = [[ExitWatcher alloc] init];
	NSDate *deadline;

	setvbuf(stdout, NULL, _IONBF, 0);

	check(session != nil, "a session can be made");
	if (session == nil) {
		[pool release];
		return 2;
	}
	grid = [session grid];
	[session setDelegate:watcher];
	check([grid columns] == 80 && [grid rows] == 24, "with the screen it was asked for");

	check([session startWithShell:@"/bin/sh"], "a shell starts on a pty");
	if (![session isRunning]) {
		printf("\nterminal_session: the shell did not start, so nothing else can be checked\n");
		[watcher release];
		[session release];
		[pool release];
		return 1;
	}

	/* 1. THE SIZE THE CHILD INHERITS IS THE SCREEN'S, asked of the kernel with `stty`. */
	[session writeString:@"stty size\n"];
	check(wait_for_text(grid, @"24 80", 5.0), "the child's own TIOCGWINSZ answers the screen's size (24 80)");
	check([screen_text(grid) rangeOfString:@"stty size"].location != NSNotFound,
	      "and the echo shows the tty's line discipline is live, not a pipe");

	/* 2. OUTPUT MAKES IT THROUGH THE EMULATOR, escapes and all. */
	[session writeString:@"printf '\\033[1;32mCOLORED\\033[0m\\n'\n"];
	check(wait_for_text(grid, @"COLORED", 5.0), "a coloured line arrives in the grid as its text");

	/* 3. A RESIZE REACHES THE CHILD AS SIGWINCH. */
	[session resizeToColumns:100 rows:33];
	[session writeString:@"stty size\n"];
	check(wait_for_text(grid, @"33 100", 5.0), "a resize after the launch reaches the child as SIGWINCH (33 100)");

	/* 4. THE CHILD'S EXIT IS AN EVENT, not a silent freeze. */
	[session writeString:@"exit\n"];
	deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
	while ([session isRunning] && [deadline timeIntervalSinceNow] > 0.0) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
	check(![session isRunning], "the shell's exit is noticed");
	/* ONE MORE PASS, because the delegate's call and the flag are both set from the reaper's handler. */
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	check(watcher->exits == 1, "and reported to the delegate exactly once");

	[watcher release];
	[session release];
	[pool release];

	printf("\nterminal_session: %d check(s), %d failed\n", checks, failures);
	return failures == 0 ? 0 : 1;
}
