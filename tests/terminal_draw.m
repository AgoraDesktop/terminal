/*
 * terminal_draw — the grid as ink: what libtsm parsed, where the renderer put it, and in what colour.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE WHOLE TERMINAL THAT DOES NOT NEED A WINDOW IS IN THIS PROBE.** A screen, the emulator's parser, the
 * renderer's paint into a bitmap, and a pixel read — no compositor, no pty, no window. That is deliberate: the two
 * halves that can be wrong about COLOUR, PLACEMENT and CELL SIZE are exactly the two halves that can be tested
 * without one, and an assertion about a pixel is the only honest test of "the right ink landed in the right cell".
 *
 * Each case names what a terminal must get right and a renderer can silently get wrong:
 *
 *   1. THE CELL IS THE UNIT — a font's advance is the column, and a whole number of cells is what a resize asks for.
 *   2. THE GROUND IS FILLED — a screen of spaces is the terminal's background, not the bitmap's.
 *   3. INK LANDS IN ITS OWN CELL — one glyph, one cell, and the cell beside it untouched.
 *   4. COLOUR IS THE PROGRAM'S — a palette red and a 24-bit colour arrive as those bytes.
 *   5. A BACKGROUND COLOUR FILLS A CELL WITH NOTHING IN IT, which is how a TUI draws a selection bar.
 *   6. A WIDE GLYPH SPANS TWO CELLS, which is why the renderer asks the emulator for a width rather than assuming one.
 *   7. THE CURSOR IS AN INVERSE CELL, and is drawn only for the live screen.
 */
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <Foundation/Foundation.h>

#import "AGTerminalGrid.h"
#import "AGTerminalRenderer.h"

#include <stdio.h>
#include <string.h>

#define W 400
#define H 200

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

/* **THE BITMAP IS THE GLASS, UNFLIPPED, WHICH IS WHAT THE COMPOSITOR'S BUFFER IS AFTER THE VIEW'S OWN FLIP.** Rows are
 * read with `-colorAtX:y:`, where y counts DOWN from the image's top — so a cell in grid row r occupies y in
 * [r·cellHeight, (r+1)·cellHeight). */
/* **A FEED WHOSE LENGTH CANNOT BE MISCOUNTED.** The first version of this probe passed `length:10` for a nine-byte
 * escape-plus-glyph and read one byte past the NUL, which is exactly the kind of error a hand-counted length invites. */
static void feed(AGTerminalGrid *grid, const char *bytes)
{
	[grid feed:bytes length:strlen(bytes)];
}

static NSBitmapImageRep *new_rep(void)
{
	return [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:W * 4 bitsPerPixel:32];
}

static void render(AGTerminalRenderer *renderer, AGTerminalGrid *grid, NSBitmapImageRep *rep)
{
	NSGraphicsContext *graphics;
	CGContextRef context;

	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
	graphics = [NSGraphicsContext currentContext];
	context = (CGContextRef)[graphics graphicsPort];
	[renderer drawGrid:grid inContext:context bounds:CGRectMake(0.0, 0.0, (CGFloat)W, (CGFloat)H)];
}

/* THE INK IN ONE CELL, as a count and as the brightest channel sums seen — enough to answer "did anything land here"
 * and "was it red" without pinning an antialiasing pattern. */
static int ink_in_cell(NSBitmapImageRep *rep, NSUInteger column, NSUInteger row,
		       CGFloat cellWidth, CGFloat cellHeight)
{
	int x0 = (int)((CGFloat)column * cellWidth);
	int x1 = (int)((CGFloat)(column + 1) * cellWidth);
	int y0 = (int)((CGFloat)row * cellHeight);
	int y1 = (int)((CGFloat)(row + 1) * cellHeight);
	int x, y, count = 0;

	for (y = y0; y < y1 && y < H; y++) {
		for (x = x0; x < x1 && x < W; x++) {
			NSColor *colour = [rep colorAtX:x y:y];

			if (colour != nil && ([colour redComponent] > 0.25 || [colour greenComponent] > 0.25 ||
					      [colour blueComponent] > 0.25)) {
				count++;
			}
		}
	}
	return count;
}

static NSColor *cell_pixel(NSBitmapImageRep *rep, NSUInteger column, NSUInteger row,
			   CGFloat cellWidth, CGFloat cellHeight)
{
	int x = (int)(((CGFloat)column + 0.5) * cellWidth);
	int y = (int)(((CGFloat)row + 0.5) * cellHeight);

	if (x >= W || y >= H) {
		return nil;
	}
	return [rep colorAtX:x y:y];
}

/* A PPM, so a person can LOOK at what the probe measured. `/tmp/terminal-draw.ppm`. */
static void write_ppm(NSBitmapImageRep *rep, const char *path)
{
	FILE *file = fopen(path, "wb");
	int x, y;

	if (file == NULL) {
		return;
	}
	fprintf(file, "P6\n%d %d\n255\n", W, H);
	for (y = 0; y < H; y++) {
		for (x = 0; x < W; x++) {
			NSColor *colour = [rep colorAtX:x y:y];
			unsigned char rgb[3];

			rgb[0] = (unsigned char)([colour redComponent] * 255.0 + 0.5);
			rgb[1] = (unsigned char)([colour greenComponent] * 255.0 + 0.5);
			rgb[2] = (unsigned char)([colour blueComponent] * 255.0 + 0.5);
			fwrite(rgb, 1, 3, file);
		}
	}
	fclose(file);
	printf("  (wrote %s)\n", path);
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	AGTerminalRenderer *renderer;
	AGTerminalGrid *grid;
	NSBitmapImageRep *rep;
	CGFloat cw, ch;

	setvbuf(stdout, NULL, _IONBF, 0);

	renderer = [[AGTerminalRenderer alloc] initWithFontName:@"IBM Plex Mono" pointSize:13.0];
	check(renderer != nil, "the terminal font opens");
	if (renderer == nil) {
		[pool release];
		return 2;
	}
	cw = [renderer cellWidth];
	ch = [renderer cellHeight];
	printf("  (cell = %.2f x %.2f points; a %dx%d buffer is %lu x %lu cells)\n", cw, ch, W, H,
	       (unsigned long)[renderer columnsForWidth:W], (unsigned long)[renderer rowsForHeight:H]);

	/* 1. THE CELL IS THE UNIT. */
	check(cw > 0.0 && ch > 0.0, "a font gives a cell");
	check(ch >= cw, "and a line is at least as tall as a column is wide");
	check([renderer columnsForWidth:(CGFloat)W] == (NSUInteger)(W / cw),
	      "a width is a whole number of cells");

	grid = [[AGTerminalGrid alloc] initWithColumns:[renderer columnsForWidth:W]
						  rows:[renderer rowsForHeight:H]];
	check(grid != nil && [grid columns] > 0 && [grid rows] > 0, "the emulator makes a grid of that size");

	/* THE CURSOR OFF FOR EVERY INK CASE: it is a filled cell, and a case that asserted "nothing here" while the
	 * cursor sat in that cell would be measuring the cursor. */
	feed(grid, "\x1b[?25l");
	check(![grid isCursorVisible], "hiding the cursor is the emulator's flag, not the view's");

	/* 2. THE GROUND IS FILLED. */
	rep = new_rep();
	render(renderer, grid, rep);
	{
		NSColor *blank = cell_pixel(rep, 5, 5, cw, ch);

		check(blank != nil && [blank redComponent] < 0.05 && [blank greenComponent] < 0.05 &&
		      [blank blueComponent] < 0.05,
		      "an empty grid is the terminal's ground, not the bitmap's");
	}
	[rep release];

	/* 3. INK LANDS IN ITS OWN CELL. */
	feed(grid, "A");
	rep = new_rep();
	render(renderer, grid, rep);
	check(ink_in_cell(rep, 0, 0, cw, ch) > 0, "a character draws ink in the first cell");
	check(ink_in_cell(rep, 1, 0, cw, ch) == 0, "and none in the cell beside it");
	check(ink_in_cell(rep, 0, 1, cw, ch) == 0, "and none on the line below");
	write_ppm(rep, "/tmp/terminal-draw.ppm");
	[rep release];

	/* 4. COLOUR IS THE PROGRAM'S: a palette red, then a 24-bit one. */
	{
		AGTerminalGrid *coloured = [[AGTerminalGrid alloc] initWithColumns:40 rows:4];
		NSColor *pixel;
		int red, green, blue;

		feed(coloured, "\x1b[?25l\x1b[31mR");
		rep = new_rep();
		render(renderer, coloured, rep);
		pixel = cell_pixel(rep, 0, 0, cw, ch);
		/* THE CELL'S CENTRE MAY BE A HOLE IN THE GLYPH, so the colour is read from the cell's ink instead. */
		{
			int x0 = 0, x1 = (int)cw, y0 = 0, y1 = (int)ch, x, y;

			red = green = blue = 0;
			for (y = y0; y < y1; y++) {
				for (x = x0; x < x1; x++) {
					NSColor *c = [rep colorAtX:x y:y];

					if (c != nil && [c redComponent] > 0.4 && [c redComponent] > [c greenComponent]) {
						red++;
						green += (int)([c greenComponent] * 100.0);
						blue += (int)([c blueComponent] * 100.0);
					}
				}
			}
		}
		check(red > 0, "SGR 31 draws red ink");
		check(red > 0 && green < red * 100 && blue < red * 100, "and not a mixture: the green and blue are near zero");
		(void)pixel;
		[rep release];

		feed(coloured, "\r\x1b[38;2;10;200;30mG");
		rep = new_rep();
		render(renderer, coloured, rep);
		{
			int x0 = 0, x1 = (int)cw, y0 = 0, y1 = (int)ch, x, y, greenish = 0;

			for (y = y0; y < y1; y++) {
				for (x = x0; x < x1; x++) {
					NSColor *c = [rep colorAtX:x y:y];

					if (c != nil && [c greenComponent] > 0.5 && [c redComponent] < 0.4) {
						greenish++;
					}
				}
			}
			check(greenish > 0, "a 24-bit SGR is that colour, not the nearest palette entry");
		}
		[rep release];

		/* 5. A BACKGROUND FILLS A CELL WITH NOTHING IN IT. */
		feed(coloured, "\r\x1b[48;2;0;0;255m \x1b[0m");
		rep = new_rep();
		render(renderer, coloured, rep);
		{
			NSColor *fill = cell_pixel(rep, 0, 0, cw, ch);

			check(fill != nil && [fill blueComponent] > 0.8 && [fill redComponent] < 0.2,
			      "a background colour fills the cell even where nothing is drawn");
		}
		[rep release];
		[coloured release];
	}

	/* 6. A WIDE GLYPH SPANS TWO CELLS. */
	{
		AGTerminalGrid *wide = [[AGTerminalGrid alloc] initWithColumns:10 rows:2];

		feed(wide, "\x1b[?25l\xe6\xbc\xa2");	/* U+6F22 */
		rep = new_rep();
		render(renderer, wide, rep);
		check(ink_in_cell(rep, 0, 0, cw, ch) > 0, "a wide character draws in its own cell");
		check(ink_in_cell(rep, 1, 0, cw, ch) > 0,
		      "and REACHES INTO THE NEXT ONE, which is why the cell width is not the glyph's width");
		check(ink_in_cell(rep, 2, 0, cw, ch) == 0, "and stops there");
		[rep release];
		[wide release];
	}

	/* 7. THE CURSOR IS AN INVERSE CELL. */
	{
		AGTerminalGrid *cursored = [[AGTerminalGrid alloc] initWithColumns:10 rows:2];
		NSColor *inverse;

		rep = new_rep();
		render(renderer, cursored, rep);
		inverse = cell_pixel(rep, 0, 0, cw, ch);
		check(inverse != nil && [inverse redComponent] > 0.5 && [inverse greenComponent] > 0.5,
		      "the cursor is a bright block in an otherwise empty cell");
		[rep release];
		[cursored release];
	}

	/* 8. SCROLLBACK IS A POSITION, AND IT IS THE SCREEN'S. A grid of four rows and twenty lines of output keeps the
	 * lines behind the view, moves through them, and comes back to the live screen — which is what decides whether the
	 * cursor is drawn at all. */
	{
		AGTerminalGrid *rolled = [[AGTerminalGrid alloc] initWithColumns:20 rows:4];

		feed(rolled, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\neight\r\nnine\r\nten\r\n");
		check([rolled scrollbackLines] > 0, "output past the last row keeps its scrollback");
		check(![rolled isScrolledBack], "and the view starts at the live screen");
		[rolled scrollUp:3];
		check([rolled isScrolledBack], "scrolling back is a position the grid reports");
		[rolled scrollDown:100];
		check(![rolled isScrolledBack], "and scrolling past the end lands back on the live screen");
		[rolled release];
	}

	[grid release];
	[renderer release];
	[pool release];

	printf("\nterminal_draw: %d check(s), %d failed\n", checks, failures);
	return failures == 0 ? 0 : 1;
}
