/*
 * terminal_view — the VIEW's own paint, driven through the AppKit's door and read back as pixels.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **WHY THIS EXISTS WHEN `terminal_draw` ALREADY READS PIXELS.** That probe calls the renderer directly, which proves
 * the paint and says nothing about whether a VIEW is ever asked to paint, whether it finds a context, or whether what
 * it draws is clipped away. This one builds the real `AGTerminalView` — the same class the application puts in a
 * window — gives it a `NSGraphicsContext` over a bitmap, and calls `-displayRect:`, which is the AppKit's own
 * dispatch: the same `-drawRect:` a window's frame path calls, with the same clip and the same current context.
 *
 * The window itself is the one thing that still needs a compositor, and it is the one thing that has no pixels of its
 * own — so this is every pixel the application draws, without one.
 */
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <Foundation/Foundation.h>

#import "AGTerminalGrid.h"
#import "AGTerminalRenderer.h"
#import "AGTerminalSession.h"
#import "AGTerminalView.h"

#include <stdio.h>
#include <string.h>

#define VW 320
#define VH 120

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

/* A FEED WHOSE LENGTH CANNOT BE MISCOUNTED — the same lesson `terminal_draw` learned. */
static void feed(AGTerminalGrid *grid, const char *bytes)
{
	[grid feed:bytes length:strlen(bytes)];
}

static int ink_in_cell(NSBitmapImageRep *rep, NSUInteger column, NSUInteger row,
		       CGFloat cellWidth, CGFloat cellHeight)
{
	int x0 = (int)((CGFloat)column * cellWidth), x1 = (int)((CGFloat)(column + 1) * cellWidth);
	int y0 = (int)((CGFloat)row * cellHeight), y1 = (int)((CGFloat)(row + 1) * cellHeight);
	int x, y, count = 0;

	for (y = y0; y < y1 && y < VH; y++) {
		for (x = x0; x < x1 && x < VW; x++) {
			NSColor *colour = [rep colorAtX:x y:y];

			if (colour != nil && ([colour redComponent] > 0.25 || [colour greenComponent] > 0.25 ||
					      [colour blueComponent] > 0.25)) {
				count++;
			}
		}
	}
	return count;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	AGTerminalRenderer *renderer = [[AGTerminalRenderer alloc] initWithFontName:@"IBM Plex Mono" pointSize:13.0];
	AGTerminalSession *session;
	AGTerminalView *view;
	NSBitmapImageRep *rep;
	NSGraphicsContext *graphics;
	NSUInteger columns, rows;
	CGFloat cw, ch;

	setvbuf(stdout, NULL, _IONBF, 0);

	check(renderer != nil, "the font opens");
	if (renderer == nil) {
		[pool release];
		return 2;
	}
	cw = [renderer cellWidth];
	ch = [renderer cellHeight];
	columns = [renderer columnsForWidth:VW];
	rows = [renderer rowsForHeight:VH];
	printf("  (cell %.2f x %.2f; the view is %lu x %lu cells)\n", cw, ch, (unsigned long)columns,
	       (unsigned long)rows);

	session = [[AGTerminalSession alloc] initWithColumns:columns rows:rows];
	check(session != nil, "a session exists without a shell, which is what a test needs");
	view = [[AGTerminalView alloc] initWithFrame:NSMakeRect(0.0, 0.0, VW, VH)
					    session:session
					   renderer:renderer];
	check(view != nil, "the view is built from them");
	check([view isFlipped] == NO, "and is not flipped: the renderer mirrors the grid, not the glyphs");

	/* **THE DISPATCH THE WINDOW USES, WITH A BITMAP FOR A GLASS.** `-displayRect:` is what the frame path calls; it
	 * saves the state, sets the clip, calls `-drawRect:` and restores. */
	rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:VW pixelsHigh:VH
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:VW * 4 bitsPerPixel:32];
	graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
	[NSGraphicsContext setCurrentContext:graphics];

	/* An empty grid: the ground, and nothing else. */
	[view displayRect:[view bounds]];
	check(ink_in_cell(rep, 3, 3, cw, ch) == 0, "an empty session paints the ground and no ink");

	/* Text that the shell would have produced, fed through the emulator into the grid. */
	feed([session grid], "\x1b[?25lhello\x1b[0m");
	[view displayRect:[view bounds]];
	check(ink_in_cell(rep, 0, 0, cw, ch) > 0, "and a line of output paints ink in the first cell");
	check(ink_in_cell(rep, 1, 0, cw, ch) > 0, "and in the second, where the next character is");
	check(ink_in_cell(rep, 3, 3, cw, ch) == 0, "and nowhere else");

	/* A PICTURE OF A REAL SCREEN, so the probe's pixels can be CHECKED BY EYE as well as by arithmetic: a prompt, a
	 * coloured line, a box-drawing glyph and a CJK character — the four things a terminal renders that a font alone
	 * cannot. `/tmp/terminal-view.ppm`. */
	feed([session grid], "\x1b[2J\x1b[H");
	feed([session grid], "kyle@agora:~$ ls\r\n");
	feed([session grid], "\x1b[1;34msrc\x1b[0m  \x1b[1;34mlib\x1b[0m  \x1b[32mREADME.md\x1b[0m\r\n");
	feed([session grid], "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 \xe6\xbc\xa2\xe5\xad\x97\r\n");
	feed([session grid], "kyle@agora:~$ \x1b[?25h");
	[view displayRect:[view bounds]];
	{
		FILE *file = fopen("/tmp/terminal-view.ppm", "wb");
		int x, y;

		if (file != NULL) {
			fprintf(file, "P6\n%d %d\n255\n", VW, VH);
			for (y = 0; y < VH; y++) {
				for (x = 0; x < VW; x++) {
					NSColor *colour = [rep colorAtX:x y:y];
					unsigned char rgb[3];

					rgb[0] = (unsigned char)([colour redComponent] * 255.0 + 0.5);
					rgb[1] = (unsigned char)([colour greenComponent] * 255.0 + 0.5);
					rgb[2] = (unsigned char)([colour blueComponent] * 255.0 + 0.5);
					fwrite(rgb, 1, 3, file);
				}
			}
			fclose(file);
			printf("  (wrote /tmp/terminal-view.ppm)\n");
		}
	}

	[graphics release];
	[rep release];
	[view release];
	[session release];
	[renderer release];
	[pool release];

	printf("\nterminal_view: %d check(s), %d failed\n", checks, failures);
	return failures == 0 ? 0 : 1;
}
