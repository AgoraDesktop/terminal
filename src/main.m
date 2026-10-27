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

/* **A BAR'S TITLES ARE MENUS, AND THE LEAF ROWS ARE WHAT IS INSIDE THEM.** The first version of this function added
 * four bare titles to the main menu with no submenus, so the menu bar came out as one flat row — "Terminal  Quit
 * Terminal  Edit  Copy  Paste  Shell" — which is not a menu bar but a list of commands pretending to be one. Every
 * top-level item is a title whose CONTENT is a submenu (`-setSubmenu:`), and the commands live one level down.
 *
 * AND THE ITEMS EXIST BECAUSE A COMMAND KEY NEVER REACHES A VIEW: `NSApplication` offers the main menu first, so Copy,
 * Paste and Quit are items here or they do not exist. */
static NSMenuItem *fn_bar_title(NSString *title, NSMenu *submenu)
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];

	[item setSubmenu:submenu];
	return [item autorelease];
}

/* ONE ROW. A nil key means NO key equivalent, and then the mask is zeroed as well, so an empty key string can never be
 * matched by an event that happens to carry the mask. */
static NSMenuItem *fn_row(NSMenu *menu, NSString *title, SEL action, id target, NSString *key, NSUInteger mask)
{
	NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:(key != nil) ? key : @""];

	[item setTarget:target];
	[item setKeyEquivalentModifierMask:((key != nil) && [key length] > 0) ? mask : 0];
	return item;
}

static void fn_install_menu(NSApplication *application)
{
	NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
	NSMenu *app = [[NSMenu alloc] initWithTitle:@"Terminal"];
	NSMenu *shell = [[NSMenu alloc] initWithTitle:@"Shell"];
	NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];

	/* THE APPLICATION MENU. Apple's first item is the application's own, and this tier's NSApplication treats it the
	 * same way: a row whose action is NULL is a title, and the rows below it are the application's. */
	fn_row(app, @"Hide Terminal", @selector(hide:), application, @"h", NSCommandKeyMask);
	[app addItem:[NSMenuItem separatorItem]];
	fn_row(app, @"Quit Terminal", @selector(terminate:), application, @"q", NSCommandKeyMask);

	/* THE SHELL MENU, which is where a terminal's own window commands belong: closing the window ends the session. */
	fn_row(shell, @"Close Window", @selector(performClose:), nil, @"w", NSCommandKeyMask);

	/* THE EDIT MENU. Copy refuses until the view has a selection and says so in its own door; Paste is wired. */
	fn_row(edit, @"Copy", @selector(copy:), nil, @"c", NSCommandKeyMask);
	fn_row(edit, @"Paste", @selector(paste:), nil, @"v", NSCommandKeyMask);

	[main addItem:fn_bar_title(@"Terminal", app)];
	[main addItem:fn_bar_title(@"Shell", shell)];
	[main addItem:fn_bar_title(@"Edit", edit)];

	[application setMainMenu:main];
	[edit release];
	[shell release];
	[app release];
	[main release];
}

/* **A BOUNDED RUN IS A PUMP, NOT A DEADLINE ON A METHOD THAT DOES NOT EXIST.** `NSApplication -runUntilDate:` is not
 * in this AppKit, so the windowed test path drives the ordinary pump. AND IT RUNS THE RUN LOOP FIRST, because draining
 * the event queue alone never services the pty's `NSFileHandle` readability source: MEASURED, a bounded run with a
 * shell printing every 100 ms drew four frames in five seconds and the screen stayed frozen while the grid behind it
 * filled. */
static void fn_run_for(NSApplication *application, double seconds)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

	while ([deadline timeIntervalSinceNow] > 0.0) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSEvent *event;

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
