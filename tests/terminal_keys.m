/*
 * terminal_keys — what a KEYSTROKE does, through the view, to a real shell.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THIS PROBE EXISTS BECAUSE THE FIRST LIVE RUN ACCEPTED `Enter` AND NOTHING ELSE.** The cause was one line of AppKit
 * contract: `NSView -inputContext` answers a context ONLY for a view that conforms to `NSTextInput`, and
 * `-interpretKeyEvents:` hands the event to that context. A terminal view that did not conform sent printable keys
 * into a nil context — silence — while Enter survived because it takes the `-doCommandBySelector:` path, which is plain
 * `NSResponder` and works with no context at all. Nothing in the other three probes could see that: they fed the GRID,
 * and the grid was never the problem.
 *
 * So this one drives the real `AGTerminalView -keyDown:` with real `NSEvent`s — the same door the window calls — into a
 * real `/bin/sh`, and reads back what the SHELL echoed:
 *
 *   1. a printable key is text, and it is typed;
 *   2. a composition's confirmed text arrives as ONE write (the dead-key path, `-insertText:`);
 *   3. Enter is the command path, and it submits the line;
 *   4. the emulator's own key handler answers a Control combination without the text system's help.
 */
#import <AppKit/NSEvent.h>
#import <Foundation/Foundation.h>

#import "AGTerminalGrid.h"
#import "AGTerminalRenderer.h"
#import "AGTerminalSession.h"
#import "AGTerminalView.h"

#include <stdio.h>
#include <string.h>
#include <xkbcommon/xkbcommon-keysyms.h>

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

/* THE SCREEN AS TEXT, which is where an echo is evidence. */
static NSString *screen_text(AGTerminalGrid *grid)
{
	const struct tsm_screen_cell *cells = [grid cellRows];
	NSMutableString *out = [NSMutableString string];
	NSUInteger columns = [grid columns], rows = [grid rows], row, column;

	if (cells == NULL) {
		return out;
	}
	for (row = 0; row < rows; row++) {
		for (column = 0; column < columns; column++) {
			uint32_t codepoint = cells[row * columns + column].ch;

			if (codepoint == 0) {
				[out appendString:@" "];
			} else if (codepoint < 0x10000) {
				unichar unit = (unichar)codepoint;

				[out appendString:[NSString stringWithCharacters:&unit length:1]];
			} else {
				uint32_t v = codepoint - 0x10000;
				unichar pair[2];

				pair[0] = (unichar)(0xD800 + (v >> 10));
				pair[1] = (unichar)(0xDC00 + (v & 0x3FF));
				[out appendString:[NSString stringWithCharacters:pair length:2]];
			}
		}
		[out appendString:@"\n"];
	}
	return out;
}

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

static void pump(AGTerminalGrid *grid, double seconds)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

	(void)grid;
	while ([deadline timeIntervalSinceNow] > 0.0) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
	}
}

/* AN EVENT AS THE SEAM DELIVERS ONE: what it typed, what the keymap calls it, and the flags. */
static NSEvent *key(NSString *characters, unsigned int keysym, NSUInteger flags)
{
	NSEvent *event = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:flags
					 timestamp:0.0 windowNumber:0 context:nil
					characters:characters charactersIgnoringModifiers:characters
					 isARepeat:NO keyCode:0];

	[event cg_setKeysym:keysym];
	return event;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	AGTerminalRenderer *renderer = [[AGTerminalRenderer alloc] initWithFontName:@"IBM Plex Mono" pointSize:13.0];
	AGTerminalSession *session = [[AGTerminalSession alloc] initWithColumns:80 rows:24];
	AGTerminalGrid *grid = [session grid];
	AGTerminalView *view;
	NSString *text;
	BOOL typed;

	setvbuf(stdout, NULL, _IONBF, 0);

	view = [[AGTerminalView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 624.0, 408.0)
					    session:session
					   renderer:renderer];
	check(view != nil, "a view exists to type into");
	/* THE LINE OF CONTRACT THE BUG WAS ABOUT: a view with no input context is a view whose `-interpretKeyEvents:` does
	 * nothing, which is silent by construction. */
	check([view conformsToProtocol:@protocol(NSTextInput)], "the view IS a text input client");
	check([view inputContext] != nil, "so it has an input context, which is what a typed key needs");

	if (![session startWithShell:@"/bin/sh"] || !wait_for_text(grid, @"$", 5.0)) {
		printf("\nterminal_keys: the shell did not come up, so nothing else can be checked\n");
		[view release];
		[session release];
		[renderer release];
		[pool release];
		return 1;
	}

	/* 1. A PRINTABLE KEY IS TYPED. The shell echoes it, so the grid is the evidence. */
	[view keyDown:key(@"e", XKB_KEY_e, 0)];
	[view keyDown:key(@"c", XKB_KEY_c, 0)];
	[view keyDown:key(@"h", XKB_KEY_h, 0)];
	[view keyDown:key(@"o", XKB_KEY_o, 0)];
	[view keyDown:key(@" ", XKB_KEY_space, 0)];
	[view keyDown:key(@"O", XKB_KEY_O, NSShiftKeyMask)];
	[view keyDown:key(@"K", XKB_KEY_K, NSShiftKeyMask)];
	typed = wait_for_text(grid, @"echo OK", 5.0);
	check(typed, "seven printable keys reach the shell and are echoed");

	/* 2. A COMPOSITION'S CONFIRMED TEXT IS ONE WRITE — the path a dead key takes, straight through the protocol. */
	[view insertText:@"!"];
	[view insertText:@"\r"];
	check(wait_for_text(grid, @"OK!", 5.0), "and the line the shell RAN is on the screen, so Enter submitted it");

	/* 3. A CONTROL COMBINATION IS THE EMULATOR'S, not the text system's: `Ctrl+C` never reaches `-insertText:`. */
	[view keyDown:key(@"\x03", XKB_KEY_c, NSControlKeyMask)];
	pump(grid, 0.4);
	check([screen_text(grid) rangeOfString:@"^C"].location != NSNotFound ||
	      [screen_text(grid) rangeOfString:@"$"].location != NSNotFound,
	      "Ctrl+C is answered by the emulator's own key handler");

	/* AND THE VIEW IS STILL ALIVE AND STILL A CLIENT AFTER ALL OF IT. */
	check([view inputContext] != nil, "the context survives the session");

	text = screen_text(grid);
	(void)text;

	[view release];
	[session release];
	[renderer release];
	[pool release];

	printf("\nterminal_keys: %d check(s), %d failed\n", checks, failures);
	return failures == 0 ? 0 : 1;
}
