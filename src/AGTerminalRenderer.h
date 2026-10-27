/*
 * AGTerminalRenderer.h — the grid as ink: cell metrics, a glyph per codepoint, and the paint.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THE RENDERER KNOWS NOTHING ABOUT WINDOWS AND NOTHING ABOUT PTYS. It turns a cell table into pixels in a
 * `CGContext` the caller owns, which is what makes it testable without a compositor: `tests/terminal_draw.m` paints
 * into a bitmap and reads the pixels back.
 *
 * **THE CELL IS THE UNIT, AND EVERY METRIC COMES FROM ONE GLYPH.** A terminal's whole layout is "column × advance,
 * row × line height", so the renderer measures the font once — the advance of `M`, and ascent + descent + leading —
 * and everything else is multiplication. A font whose glyphs do NOT all share that advance is not a terminal font,
 * and the answer for one is a different font rather than per-cell advances.
 */
#ifndef AG_TERMINAL_RENDERER_H
#define AG_TERMINAL_RENDERER_H

#import <Foundation/Foundation.h>
#include <CoreGraphics/CGContext.h>
#include <CoreGraphics/CGGeometry.h>
#include <libtsm.h>

@class AGTerminalGrid;

@interface AGTerminalRenderer : NSObject
{
	void *_font;			/* CTFontRef, held without CoreText's name in this header */
	void *_graphicsFont;		/* CGFontRef, made once: what `CGContextSetFont` takes */
	CGFloat _pointSize;
	CGFloat _cellWidth;
	CGFloat _cellHeight;
	CGFloat _ascent;
	CGFloat _descent;
	/* THE ASCII FAST PATH. A terminal spends its life in the first 8 000 codepoints, so the glyph for those is an
	 * array read; anything else goes through a dictionary, which is a slow path that is also the rare one. */
	CGGlyph _glyphs[0x2000];
	BOOL _known[0x2000];
	NSMutableDictionary *_otherGlyphs;	/* NSNumber codepoint → NSNumber (font index << 16 | glyph) */
	/* **THE FALLBACK CHAIN, BECAUSE A TERMINAL FONT IS A MONOSPACE FACE AND MONOSPACE FACES HAVE NO CJK.** The
	 * primary font is slot 0; a codepoint it cannot draw asks Core Text's cascade (`CTFontCreateForString`) for a font
	 * that can, and the answer is kept. Nine slots rather than an unbounded list: a terminal's non-Latin text is
	 * ordinarily one script plus an emoji face, and a limit that is stated is better than a cache that grows. */
	void *_fonts[9];			/* CTFontRef: [0] is the primary */
	void *_graphicsFonts[9];		/* CGFontRef, one per font */
	NSUInteger _fontCount;
	CGFloat _defaultInk[4];
	CGFloat _defaultGround[4];
}

- (id)initWithFontName:(NSString *)fontName pointSize:(CGFloat)pointSize;

- (CGFloat)cellWidth;
- (CGFloat)cellHeight;
- (CGFloat)ascent;
- (CGFloat)descent;

/* How many whole cells fit, which is the question a resize asks. */
- (NSUInteger)columnsForWidth:(CGFloat)width;
- (NSUInteger)rowsForHeight:(CGFloat)height;

- (void)setDefaultInkRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b;
- (void)setDefaultGroundRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b;

/* **A CONTEXT WHOSE ORIGIN IS BOTTOM-LEFT AND UNFLIPPED**, which is a bitmap context's own convention and what the
 * compositor's buffer gives after the view has done its flipping. The grid is TOP-DOWN, so the row arithmetic below
 * mirrors it once, here, rather than in every caller. */
- (void)drawGrid:(AGTerminalGrid *)grid inContext:(CGContextRef)context bounds:(CGRect)bounds;

/* The glyph for one codepoint in this renderer's font; 0 (`.notdef`) when the font has none. Public because a test
 * asks it directly, and because a fallback chain will hang off it. */
- (CGGlyph)glyphForCodepoint:(uint32_t)codepoint;

@end

#endif /* AG_TERMINAL_RENDERER_H */
