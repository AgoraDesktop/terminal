/*
 * AGTerminalRenderer.m — the paint, and the cache that makes it cheap.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "AGTerminalRenderer.h"
#import "AGTerminalGrid.h"

#include <CoreText/CTFont.h>
#include <CoreGraphics/CGColorSpace.h>
#include <math.h>

/* **THE GLYPH FOR A CODEPOINT, THROUGH UTF-16 BECAUSE THAT IS WHAT CORE TEXT TAKES.** A codepoint below U+10000 is
 * one unit; above it is a surrogate pair, and `CTFontGetGlyphsForCharacters` refuses the whole request if ANY unit
 * fails to map — so a pair that the font has no glyph for costs the character rather than half of it, which is the
 * right answer for a terminal cell. */
static CGGlyph fn_glyph_for(CTFontRef font, uint32_t codepoint)
{
	UniChar units[2];
	CGGlyph glyphs[2] = {0, 0};
	CFIndex count;

	if (codepoint < 0x10000) {
		units[0] = (UniChar)codepoint;
		count = 1;
	} else if (codepoint <= 0x10FFFF) {
		uint32_t v = codepoint - 0x10000;

		units[0] = (UniChar)(0xD800 + (v >> 10));
		units[1] = (UniChar)(0xDC00 + (v & 0x3FF));
		count = 2;
	} else {
		return 0;
	}
	if (!CTFontGetGlyphsForCharacters(font, units, glyphs, count)) {
		return 0;
	}
	return glyphs[0];
}

@implementation AGTerminalRenderer

- (id)initWithFontName:(NSString *)fontName pointSize:(CGFloat)pointSize
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	if (pointSize <= 0.0) {
		pointSize = 13.0;
	}
	_pointSize = pointSize;
	_font = (void *)CTFontCreateWithName((CFStringRef)(fontName != nil ? fontName : @"IBM Plex Mono"),
					     pointSize, NULL);
	if (_font == NULL) {
		[self release];
		return nil;
	}
	_graphicsFont = (void *)CTFontCopyGraphicsFont((CTFontRef)_font, NULL);
	if (_graphicsFont == NULL) {
		[self release];
		return nil;
	}
	_fonts[0] = _font;
	_graphicsFonts[0] = _graphicsFont;
	_fontCount = 1;

	/* **THE CELL, MEASURED ONCE.** The advance of `M` is the column; the line is ascent + descent + leading, rounded
	 * UP to a whole pixel so that rows land on device pixels and a full screen does not accumulate a fraction per
	 * row. The ascent is kept because the baseline of a cell is `cell bottom + descent`. */
	{
		UniChar m = 'M';
		CGGlyph glyph = 0;
		CGSize advance = CGSizeMake(pointSize * 0.6, 0.0);

		if (CTFontGetGlyphsForCharacters((CTFontRef)_font, &m, &glyph, 1)) {
			CTFontGetAdvancesForGlyphs((CTFontRef)_font, (CTFontOrientation)0, &glyph, &advance, 1);
		}
		_cellWidth = advance.width;
	}
	_ascent = CTFontGetAscent((CTFontRef)_font);
	_descent = CTFontGetDescent((CTFontRef)_font);
	_cellHeight = ceil(_ascent + _descent + CTFontGetLeading((CTFontRef)_font));

	_otherGlyphs = [[NSMutableDictionary alloc] init];
	_defaultInk[0] = 0.898;  _defaultInk[1] = 0.898;  _defaultInk[2] = 0.898;  _defaultInk[3] = 1.0;
	_defaultGround[0] = 0.0; _defaultGround[1] = 0.0; _defaultGround[2] = 0.0; _defaultGround[3] = 1.0;
	return self;
}

- (void)dealloc
{
	{
		NSUInteger i;

		for (i = 0; i < _fontCount; i++) {
			if (_graphicsFonts[i] != NULL) {
				CGFontRelease((CGFontRef)_graphicsFonts[i]);
			}
			if (_fonts[i] != NULL) {
				CFRelease((CTFontRef)_fonts[i]);
			}
		}
		_fontCount = 0;
	}
	_graphicsFont = NULL;
	_font = NULL;
	[_otherGlyphs release];
	[super dealloc];
}

- (CGFloat)cellWidth
{
	return _cellWidth;
}

- (CGFloat)cellHeight
{
	return _cellHeight;
}

- (CGFloat)ascent
{
	return _ascent;
}

- (CGFloat)descent
{
	return _descent;
}

- (NSUInteger)columnsForWidth:(CGFloat)width
{
	if (_cellWidth <= 0.0 || width <= 0.0) {
		return 0;
	}
	return (NSUInteger)floor(width / _cellWidth);
}

- (NSUInteger)rowsForHeight:(CGFloat)height
{
	if (_cellHeight <= 0.0 || height <= 0.0) {
		return 0;
	}
	return (NSUInteger)floor(height / _cellHeight);
}

- (void)setDefaultInkRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b
{
	_defaultInk[0] = r;
	_defaultInk[1] = g;
	_defaultInk[2] = b;
}

- (void)setDefaultGroundRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b
{
	_defaultGround[0] = r;
	_defaultGround[1] = g;
	_defaultGround[2] = b;
}

/* **THE FONT THAT CAN DRAW THIS CODEPOINT, WHICH IS NOT ALWAYS THE TERMINAL'S FONT.** libtsm hands over a UCS-4 value
 * and a monospace face covers Latin; for anything else Core Text's cascade is asked — `CTFontCreateForString` with the
 * primary as the starting point answers the font the system would use, at the same size. Every answer is kept in the
 * chain, so the second CJK character costs an array read. */
- (NSUInteger)fontIndexForCodepoint:(uint32_t)codepoint glyph:(CGGlyph *)outGlyph
{
	NSUInteger i;
	UniChar units[2];
	CFIndex count;
	CFStringRef string;
	CTFontRef fallback;
	CGFontRef graphics;

	if (codepoint < 0x10000) {
		units[0] = (UniChar)codepoint;
		count = 1;
	} else {
		uint32_t v = codepoint - 0x10000;

		units[0] = (UniChar)(0xD800 + (v >> 10));
		units[1] = (UniChar)(0xDC00 + (v & 0x3FF));
		count = 2;
	}
	string = CFStringCreateWithCharacters(NULL, units, count);
	if (string == NULL) {
		*outGlyph = 0;
		return 0;
	}
	fallback = CTFontCreateForString((CTFontRef)_font, string, CFRangeMake(0, count));
	CFRelease(string);
	if (fallback == NULL) {
		*outGlyph = 0;
		return 0;
	}
	*outGlyph = fn_glyph_for(fallback, codepoint);
	if (*outGlyph == 0 || _fontCount >= sizeof _fonts / sizeof _fonts[0]) {
		CFRelease(fallback);
		return 0;
	}
	graphics = CTFontCopyGraphicsFont(fallback, NULL);
	_fonts[_fontCount] = fallback;
	_graphicsFonts[_fontCount] = (void *)graphics;
	return _fontCount++;
}

- (CGGlyph)glyphForCodepoint:(uint32_t)codepoint
{
	CGGlyph glyph = 0;

	[self glyph:&glyph fontIndex:NULL forCodepoint:codepoint];
	return glyph;
}

/* The packed answer: the font's index and the glyph, so a caller can set the font when it changes. */
- (CGGlyph)glyph:(CGGlyph *)outGlyph fontIndex:(NSUInteger *)outIndex forCodepoint:(uint32_t)codepoint
{
	NSNumber *key;
	NSNumber *cached;
	uint32_t packed;

	if (codepoint < 0x2000) {
		if (!_known[codepoint]) {
			_glyphs[codepoint] = fn_glyph_for((CTFontRef)_font, codepoint);
			_known[codepoint] = YES;
		}
		if (_glyphs[codepoint] != 0) {
			if (outIndex != NULL) {
				*outIndex = 0;
			}
			*outGlyph = _glyphs[codepoint];
			return _glyphs[codepoint];
		}
	}
	key = [NSNumber numberWithUnsignedInt:codepoint];
	cached = [_otherGlyphs objectForKey:key];
	if (cached != nil) {
		packed = [cached unsignedIntValue];
		if (outIndex != NULL) {
			*outIndex = (packed >> 16);
		}
		*outGlyph = (CGGlyph)(packed & 0xFFFF);
		return *outGlyph;
	}
	{
		NSUInteger index = 0;
		CGGlyph glyph = fn_glyph_for((CTFontRef)_font, codepoint);

		if (glyph == 0) {
			index = [self fontIndexForCodepoint:codepoint glyph:&glyph];
		}
		packed = ((uint32_t)index << 16) | (uint32_t)glyph;
		[_otherGlyphs setObject:[NSNumber numberWithUnsignedInt:packed] forKey:key];
		if (outIndex != NULL) {
			*outIndex = index;
		}
		*outGlyph = glyph;
		return glyph;
	}
}

/* **THE CELL'S COLOUR, AS THE SCREEN RESOLVED IT — SET THROUGH A CGColor, NOT THROUGH COMPONENTS.**
 * libtsm's cell carries the foreground and background already in RGB (palette entries resolved, 24-bit SGR passed
 * through), so there is no palette here to disagree with the emulator's own OSC 4/10/11 answers.
 *
 * **THE COMPONENT DOOR IS THE WRONG ONE HERE, AND GETTING IT WRONG IS SILENT.** `CGContextSetFillColor` reads its
 * numbers in whatever space the context was last TOLD it is filling with — and a bitmap context's default is DEVICE
 * GRAY, so a four-component RGBA call is read as grey-plus-alpha: the ground `(0,0,0,1)` painted transparent black and
 * the ink painted grey at 89% alpha. MEASURED: the first headless screenshot of this application was a uniformly
 * coloured rectangle with no text on it, and nothing raised. `…SetFillColorWithColor` carries its own space, which is
 * what the AppKit's own window paint uses. */
static void fn_set_fill(CGContextRef context, const struct tsm_screen_color *colour)
{
	CGColorRef cg = CGColorCreateGenericRGB((CGFloat)colour->r / 255.0, (CGFloat)colour->g / 255.0,
						(CGFloat)colour->b / 255.0, 1.0);

	if (cg == NULL) {
		return;
	}
	CGContextSetFillColorWithColor(context, cg);
	CGColorRelease(cg);
}

static BOOL fn_colour_is(const struct tsm_screen_color *a, const struct tsm_screen_color *b)
{
	return a->r == b->r && a->g == b->g && a->b == b->b;
}

- (void)drawGrid:(AGTerminalGrid *)grid inContext:(CGContextRef)context bounds:(CGRect)bounds
{
	const struct tsm_screen_cell *cells;
	unsigned int columns, rows;
	unsigned int row, column;
	NSUInteger fontIndex = 0;
	CGFloat top;
	struct tsm_screen_color ground;
	CGFloat components[4];

	if (grid == nil || context == NULL) {
		return;
	}
	cells = [grid cellRows];
	columns = (unsigned int)[grid columns];
	rows = (unsigned int)[grid rows];
	if (cells == NULL || columns == 0 || rows == 0) {
		return;
	}

	/* THE GROUND, which is also what a cell with no background of its own leaves showing. Filled first and once,
	 * rather than per cell, because "no background" is the common case. */
	components[0] = _defaultGround[0];
	components[1] = _defaultGround[1];
	components[2] = _defaultGround[2];
	components[3] = 1.0;
	{
		CGColorRef groundColour = CGColorCreateGenericRGB(_defaultGround[0], _defaultGround[1],
								  _defaultGround[2], 1.0);

		if (groundColour != NULL) {
			CGContextSetFillColorWithColor(context, groundColour);
			CGColorRelease(groundColour);
		} else {
			CGContextSetFillColor(context, components);
		}
	}
	CGContextFillRect(context, bounds);

	ground.r = (uint8_t)(_defaultGround[0] * 255.0 + 0.5);
	ground.g = (uint8_t)(_defaultGround[1] * 255.0 + 0.5);
	ground.b = (uint8_t)(_defaultGround[2] * 255.0 + 0.5);

	/* THE FONT, ONCE. `CTRunDraw`'s own sequence: the graphics font and the size are context state, and setting them
	 * per glyph would be a lookup per glyph. */
	CGContextSetFont(context, (CGFontRef)_graphicsFont);
	CGContextSetFontSize(context, _pointSize);

	top = bounds.origin.y + bounds.size.height;

	for (row = 0; row < rows; row++) {
		CGFloat cellBottom = top - (CGFloat)(row + 1) * _cellHeight;

		for (column = 0; column < columns; column++) {
			const struct tsm_screen_cell *cell = &cells[(size_t)row * columns + column];
			CGFloat x = bounds.origin.x + (CGFloat)column * _cellWidth;
			uint32_t codepoint = cell->ch;

			if (!fn_colour_is(&cell->bg, &ground)) {
				fn_set_fill(context, &cell->bg);
				CGContextFillRect(context, CGRectMake(x, cellBottom, _cellWidth, _cellHeight));
			}
			if (codepoint == 0 || codepoint == ' ') {
				continue;
			}
			{
				CGGlyph glyph = 0;
				NSUInteger index = 0;
				CGPoint position;

				[self glyph:&glyph fontIndex:&index forCodepoint:codepoint];
				if (glyph == 0) {
					continue;
				}
				if (index != fontIndex) {
					fontIndex = index;
					CGContextSetFont(context, (CGFontRef)_graphicsFonts[index]);
					CGContextSetFontSize(context, CTFontGetSize((CTFontRef)_fonts[index]));
				}
				fn_set_fill(context, &cell->fg);
				position = CGPointMake(x, cellBottom + _descent);
				CGContextShowGlyphsAtPositions(context, &glyph, &position, 1);
			}
		}
	}

	/* **THE CURSOR IS AN INVERSE CELL, DRAWN LAST SO IT IS NOT PAINTED OVER.** A terminal's block cursor is the cell
	 * with its ground and ink exchanged — the glyph still shows, in the ground colour — and it is drawn only for the
	 * LIVE screen: a view scrolled back into history is showing lines the cursor is not on. */
	if ([grid isCursorVisible] && ![grid isScrolledBack]) {
		unsigned int column = [grid cursorColumn];
		unsigned int row = [grid cursorRow];

		if (column < columns && row < rows) {
			const struct tsm_screen_cell *cell = &cells[(size_t)row * columns + column];
			CGFloat x = bounds.origin.x + (CGFloat)column * _cellWidth;
			CGFloat cellBottom = top - (CGFloat)(row + 1) * _cellHeight;

			fn_set_fill(context, &cell->fg);
			CGContextFillRect(context, CGRectMake(x, cellBottom, _cellWidth, _cellHeight));
			if (cell->ch != 0 && cell->ch != ' ') {
				CGGlyph glyph = 0;
				NSUInteger index = 0;
				CGPoint position;

				[self glyph:&glyph fontIndex:&index forCodepoint:cell->ch];
				if (glyph != 0) {
					CGContextSetFont(context, (CGFontRef)_graphicsFonts[index]);
					CGContextSetFontSize(context, CTFontGetSize((CTFontRef)_fonts[index]));
					fn_set_fill(context, &cell->bg);
					position = CGPointMake(x, cellBottom + _descent);
					CGContextShowGlyphsAtPositions(context, &glyph, &position, 1);
				}
			}
		}
	}
}

@end
