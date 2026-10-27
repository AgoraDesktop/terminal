/*
 * AGTerminalSession.m — one shell, one pty, one grid.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "AGTerminalSession.h"

#import <Foundation/NSFileHandle.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSTask.h>

#include <stdio.h>

@interface AGTerminalSession (Private)
- (void)readFromMaster:(NSFileHandle *)handle;
@end

@implementation AGTerminalSession

- (id)initWithColumns:(NSUInteger)columns rows:(NSUInteger)rows
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_grid = [[AGTerminalGrid alloc] initWithColumns:columns rows:rows];
	if (_grid == nil) {
		[self release];
		return nil;
	}
	[_grid setDelegate:self];
	return self;
}

- (void)dealloc
{
	[_grid setDelegate:nil];
	[_grid release];
	[_task release];
	[super dealloc];
}

- (AGTerminalGrid *)grid
{
	return _grid;
}

- (BOOL)isRunning
{
	return _running;
}

- (BOOL)startWithShell:(NSString *)shellPath
{
	NSTask *task;
	NSFileHandle *master;
	NSString *shell = shellPath;
	NSMutableDictionary *environment;

	if (_task != nil) {
		return NO;
	}
	if (shell == nil || [shell length] == 0) {
		shell = [[NSProcessInfo processInfo] environment][@"SHELL"];
	}
	if (shell == nil || [shell length] == 0) {
		shell = @"/bin/sh";
	}

	task = [[NSTask alloc] init];
	[task setLaunchPath:shell];
	/* `-l`: a login shell, which is what a terminal window is — it reads the same startup files a person's account
	 * expects. A shell that refuses `-l` fails to launch, and that is reported rather than hidden. */
	[task setArguments:[NSArray arrayWithObject:@"-l"]];
	environment = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
	/* **`TERM` IS OURS TO SAY.** libtsm answers the escape sequences xterm-256color names, so a program that asks
	 * what kind of terminal this is gets an answer the emulator can keep. */
	[environment setObject:@"xterm-256color" forKey:@"TERM"];
	[task setEnvironment:environment];
	[task setUsesPseudoTerminal:YES];
	/* THE SIZE BEFORE THE LAUNCH, so the child's first `TIOCGWINSZ` — what a shell reads for `COLUMNS`/`LINES` —
	 * is the window's, rather than a default it would have to be corrected out of. */
	[task setPseudoterminalRows:(unsigned short)[_grid rows] columns:(unsigned short)[_grid columns]];
	/* **THE ERROR-ANSWERING LAUNCH, BECAUSE THE OTHER ONE CANNOT SAY WHY.** `-launch` in this tree is the deprecated
	 * spelling with nowhere to put a failure; a shell that does not exist would look like a terminal that opened and
	 * said nothing. */
	{
		NSError *error = nil;

		if (![task launchAndReturnError:&error]) {
			fprintf(stderr, "terminal: %s did not start: %s\n", [shell UTF8String],
				error != nil ? [[error description] UTF8String] : "no error given");
			[task release];
			return NO;
		}
	}

	_task = [task retain];
	[task release];
	_running = YES;

	master = [_task pseudoterminalHandle];
	[master setReadabilityHandler:^(NSFileHandle *handle) {
		[self readFromMaster:handle];
	}];
	[_task setTerminationHandler:^(NSTask *finished) {
		(void)finished;
		self->_running = NO;
		if (self->_delegate != nil &&
		    [self->_delegate respondsToSelector:@selector(terminalSessionDidExit:)]) {
			[self->_delegate terminalSessionDidExit:self];
		}
	}];
	return YES;
}

/* **ONE READ OF WHAT IS THERE, AND AN EMPTY READ MEANS GONE.** `-availableData` is "read to the end of the file" and
 * a pty has no end while the child lives — the first call would block the run loop for ever. A read of what the
 * source just promised is the terminal's own read; and when the child has gone the master stays readable and fails
 * with `EIO`, so the handler uninstalls itself here or the run loop spins at a hundred per cent. */
- (void)readFromMaster:(NSFileHandle *)handle
{
	NSData *chunk = [handle readDataOfLength:4096];

	if (chunk == nil || [chunk length] == 0) {
		[handle setReadabilityHandler:nil];
		return;
	}
	if (getenv("TERMINAL_PTY_DIAG") != NULL) {
		fprintf(stderr, "  DIAG pty: %lu bytes\n", (unsigned long)[chunk length]);
	}
	[_grid feedData:chunk];
	if (_delegate != nil && [_delegate respondsToSelector:@selector(terminalSessionDidProduceOutput:)]) {
		[_delegate terminalSessionDidProduceOutput:self];
	}
}

- (void)write:(NSData *)data
{
	if (_task == nil || data == nil || [data length] == 0) {
		return;
	}
	[[_task pseudoterminalHandle] writeData:data];
}

- (void)writeString:(NSString *)string
{
	if (string != nil) {
		[self write:[string dataUsingEncoding:NSUTF8StringEncoding]];
	}
}

- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows
{
	if (columns == 0 || rows == 0) {
		return;
	}
	[_grid resizeToColumns:columns rows:rows];
	if (_task != nil) {
		[_task setPseudoterminalRows:(unsigned short)rows columns:(unsigned short)columns];
	}
}

/* ---- AGTerminalGridDelegate -------------------------------------------------------------------- */

/* WHAT THE EMULATOR MUST SAY BACK — the answers to `DA1` and `DSR`, the bytes for a key it handled itself — goes to
 * the child. A session that dropped these would leave a program waiting for a reply that never came. */
- (void)terminalGrid:(AGTerminalGrid *)grid didWriteToPty:(NSData *)data
{
	(void)grid;
	[self write:data];
}

- (void)setDelegate:(id <AGTerminalSessionDelegate>)delegate
{
	_delegate = delegate;
}

- (id <AGTerminalSessionDelegate>)delegate
{
	return _delegate;
}

@end
