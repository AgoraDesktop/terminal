/*
 * main.m — a window, a shell, and the loop.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   Terminal [--seconds N] [--shell PATH] [--command MODE]
 *
 * **`--seconds` IS A TEST'S DOOR AND IS NAMED AS ONE**, the same as Workspace's: a terminal is a thing that stays, so
 * nothing bounds the run unless a caller asked. `--command` is how a probe gets a deterministic screen without
 * typing — see tests/run-terminal-headless.sh.
 */
#import <AppKit/NSApplication.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSWindow.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSProcessInfo.h>

#import "AGTerminalGrid.h"
#import "AGTerminalRenderer.h"
#import "AGTerminalSession.h"
#import "AGTerminalView.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* **THE MENU BAR EXISTS FOR FOUR ITEMS, AND THEY ARE THE ONES A TERMINAL CANNOT DO WITHOUT.** A Command key never
 * reaches a view — `NSApplication` offers it to the main menu first — so Copy, Paste, New and Quit have to be items
 * here or they do not exist. Paste is wired; Copy is the slice that needs a selection model. */
static void fn_install_menu(NSApplication *application)
{
	NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
	NSMenu *shell = [[NSMenu alloc] initWithTitle:@"Shell"];
	NSMenuItem *item;

	[main addItem:[[[NSMenuItem alloc] initWithTitle:@"Terminal" action:NULL keyEquivalent:@""] autorelease]];
	item = [[NSMenuItem alloc] initWithTitle:@"Quit Terminal" action:@selector(terminate:) keyEquivalent:@"q"];
	[item setTarget:application];
	[main addItem:item];
	[item release];

	[main addItem:[[[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""] autorelease]];
	item = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[main addItem:item];
	[item release];
	item = [[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[main addItem:item];
	[item release];

	[main addItem:[[[NSMenuItem alloc] initWithTitle:@"Shell" action:NULL keyEquivalent:@""] autorelease]];

	[application setMainMenu:main];
	[shell release];
	[main release];
}

/* **A BOUNDED RUN IS A PUMP, NOT A DEADLINE ON A METHOD THAT DOES NOT EXIST.** `NSApplication -runUntilDate:` is not
 * in this AppKit (a run loop that returns on its own is the application's business, and Workspace's subclass has its
 * own door for it), so the windowed test path drives the ordinary pump — take one event, dispatch it, breathe — and
 * stops at the deadline. The same three calls a nested run makes, which is why a probe that passes here is a probe of
 * the real dispatch path. */
static void fn_run_for(NSApplication *application, double seconds)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

	while ([deadline timeIntervalSinceNow] > 0.0) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSEvent *event;

		/* **THE RUN LOOP AND THE EVENT QUEUE ARE TWO WAITS, AND THE PTY NEEDS THE FIRST ONE.** Draining the event
		 * queue alone dispatches keys and clicks but never runs the `NSFileHandle` readability source the session's
		 * pty hangs off — MEASURED: a bounded run with a shell printing every 100 ms drew FOUR frames in five
		 * seconds, the four the window made for itself, and the screen stayed frozen while the grid behind it filled.
		 * So each pass runs the loop (which is what services every source in the mode) and then drains whatever the
		 * application put on its queue. */
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
					 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		while ((event = [application nextEventMatchingMask:NSAnyEventMask
							     untilDate:[NSDate dateWithTimeIntervalSinceNow:0.0]
								inMode:NSDefaultRunLoopMode
							       dequeue:YES]) != nil) {
			[application sendEvent:event];
		}
		[pool release];
	}
}

int main(int argc, char **argv)
{
	double seconds = 0.0;
	int bounded = 0;
	const char *shell = NULL;
	const char *command = NULL;
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
			seconds = atof(argv[++i]);
			bounded = 1;
		} else if (strcmp(argv[i], "--shell") == 0 && i + 1 < argc) {
			shell = argv[++i];
		} else if (strcmp(argv[i], "--command") == 0 && i + 1 < argc) {
			command = argv[++i];
		} else {
			fprintf(stderr, "usage: %s [--seconds N] [--shell PATH]\n", argv[0]);
			return 2;
		}
	}

	@autoreleasepool {
		NSApplication *application = [NSApplication sharedApplication];
		AGTerminalRenderer *renderer;
		AGTerminalSession *session;
		AGTerminalView *view;
		NSWindow *window;
		NSUInteger columns = 80;
		NSUInteger rows = 24;
		NSRect frame;

		[application finishLaunching];
		fn_install_menu(application);

		renderer = [[AGTerminalRenderer alloc] initWithFontName:@"IBM Plex Mono" pointSize:13.0];
		if (renderer == nil) {
			fprintf(stderr, "terminal: the terminal font could not be opened\n");
			return 1;
		}
		/* THE WINDOW IS A WHOLE NUMBER OF CELLS, which is what a terminal wants and what a fractional scale makes
		 * worth doing: 80x24 cells exactly, not a rectangle they happen to sit inside. */
		frame = NSMakeRect(80.0, 80.0,
				   (CGFloat)columns * [renderer cellWidth],
				   (CGFloat)rows * [renderer cellHeight]);

		session = [[AGTerminalSession alloc] initWithColumns:columns rows:rows];

		window = [[NSWindow alloc] initWithContentRect:frame
					     styleMask:(NSTitledWindowMask | NSClosableWindowMask |
							NSMiniaturizableWindowMask | NSResizableWindowMask)
					       backing:NSBackingStoreBuffered
						 defer:NO];
		[window setTitle:@"Terminal"];

		view = [[AGTerminalView alloc] initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height)
						    session:session
						   renderer:renderer];
		[window setContentView:view];
		[window makeFirstResponder:view];
		[window makeKeyAndOrderFront:nil];
		[application activateIgnoringOtherApps:YES];

		if (![session startWithShell:(shell != NULL ? [NSString stringWithUTF8String:shell] : nil)]) {
			fprintf(stderr, "terminal: the shell did not start\n");
		}
		if (command != NULL) {
			[session writeString:[NSString stringWithFormat:@"%s\n", command]];
		}

		if (bounded) {
			fn_run_for(application, seconds);
		} else {
			[application run];
		}

		[view release];
		[window release];
		[session release];
		[renderer release];
	}
	return 0;
}
