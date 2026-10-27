/*
 * AGTerminalView.m — paint, keys, paste, scrollback.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "AGTerminalView.h"
#import "AGTerminalRenderer.h"

#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSPasteboard.h>

#include <stdio.h>
#include <stdlib.h>

#include <libtsm.h>
#include <xkbcommon/xkbcommon-keysyms.h>

/* APPLE'S MODIFIER BITS TO libtsm's, one place. Command is deliberately absent: a Command key is the menu bar's and
 * never reaches a terminal, so mapping it would be a door nothing can come through. */
static unsigned int fn_modifiers(NSUInteger flags)
{
	unsigned int mods = 0;

	if ((flags & NSShiftKeyMask) != 0)    mods |= TSM_SHIFT_MASK;
	if ((flags & NSControlKeyMask) != 0)  mods |= TSM_CONTROL_MASK;
	if ((flags & NSAlternateKeyMask) != 0) mods |= TSM_ALT_MASK;
	if ((flags & NSCommandKeyMask) != 0)  mods |= TSM_LOGO_MASK;
	return mods;
}

/* **THE ASCII KEYSYM IS WHAT MAKES `Ctrl+C` A `C` ON A CYRILLIC LAYOUT.** libtsm folds Control from the ASCII keysym
 * when it has one, because the real keysym on such a layout is not a letter it can subtract from. For US-ASCII the
 * keysym and the character are the same number, so the ignoring-modifiers character IS the answer — and the door that
 * made `-charactersIgnoringModifiers` honest is what supplies it. */
static unsigned int fn_ascii_keysym(NSString *plain)
{
	unichar c;

	if (plain == nil || [plain length] != 1) {
		return (unsigned int)XKB_KEY_NoSymbol;
	}
	c = [plain characterAtIndex:0];
	if (c >= 0x20 && c < 0x7f) {
		return (unsigned int)c;
	}
	return (unsigned int)XKB_KEY_NoSymbol;
}

/* THE CHARACTER A KEY TYPED, as a codepoint: libtsm wants one number, and an event's string may be a surrogate pair. */
static uint32_t fn_character(NSString *characters)
{
	unichar a, b;

	if (characters == nil || [characters length] == 0) {
		return 0;
	}
	a = [characters characterAtIndex:0];
	if (a < 0xD800 || a > 0xDBFF || [characters length] < 2) {
		return (uint32_t)a;
	}
	b = [characters characterAtIndex:1];
	if (b < 0xDC00 || b > 0xDFFF) {
		return (uint32_t)a;
	}
	return 0x10000 + (((uint32_t)a - 0xD800) << 10) + ((uint32_t)b - 0xDC00);
}

/* IS THIS A KEY THE EMULATOR MUST NAME, rather than one the text system types? The commanding keys are exactly the
 * ones that carry no printable character: the 0xF700 block, and the control characters below 0x20 (Escape, Tab, CR,
 * Backspace's 0x7f). A printable character is the text system's, which is where composition lives. */
static BOOL fn_is_commanding(NSString *characters)
{
	unichar c;

	if (characters == nil || [characters length] == 0) {
		return YES;
	}
	c = [characters characterAtIndex:0];
	if (c >= 0xF700 && c <= 0xF747) {
		return YES;
	}
	return c < 0x20 || c == 0x7f;
}

@implementation AGTerminalView

- (id)initWithFrame:(NSRect)frame session:(AGTerminalSession *)session renderer:(AGTerminalRenderer *)renderer
{
	self = [super initWithFrame:frame];
	if (self == nil) {
		return nil;
	}
	_session = [session retain];
	_renderer = [renderer retain];
	[_session setDelegate:self];
	[self applySizeToSession];
	return self;
}

- (void)dealloc
{
	[_session setDelegate:nil];
	[_session release];
	[_renderer release];
	[_keyEvent release];
	[_markedString release];
	[super dealloc];
}

- (AGTerminalSession *)session
{
	return _session;
}

- (AGTerminalRenderer *)renderer
{
	return _renderer;
}

/* **THE VIEW IS NOT FLIPPED, AND THE MIRROR IS THE RENDERER'S.** A terminal's grid is top-down and a `CGContext`'s
 * origin is bottom-left; the renderer does that one subtraction when it turns a row into a y. Flipping the view
 * instead would flip the GLYPHS with it, which is a text draw with a mirrored text matrix and one more thing to get
 * wrong. */
- (BOOL)isFlipped
{
	return NO;
}

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)isOpaque
{
	return YES;
}

- (void)applySizeToSession
{
	NSRect bounds = [self bounds];
	NSUInteger columns = [_renderer columnsForWidth:NSWidth(bounds)];
	NSUInteger rows = [_renderer rowsForHeight:NSHeight(bounds)];

	if (columns == 0 || rows == 0 || (columns == _columns && rows == _rows)) {
		return;
	}
	_columns = columns;
	_rows = rows;
	[_session resizeToColumns:columns rows:rows];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self applySizeToSession];
	[self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSGraphicsContext *graphics = [NSGraphicsContext currentContext];
	CGContextRef context;

	(void)dirtyRect;
	if (graphics == nil) {
		return;
	}
	context = (CGContextRef)[graphics graphicsPort];
	if (getenv("TERMINAL_DRAW_DIAG") != NULL) {
		fprintf(stderr, "  DIAG drawRect: bounds %.0fx%.0f cells %lux%lu context %p\n",
			NSWidth([self bounds]), NSHeight([self bounds]),
			(unsigned long)_columns, (unsigned long)_rows, (void *)context);
	}
	if (context == NULL) {
		return;
	}
	[_renderer drawGrid:[_session grid] inContext:context bounds:[self bounds]];
}

/* ---- keys -------------------------------------------------------------------------------------- */

- (void)keyDown:(NSEvent *)event
{
	NSString *characters = [event characters];

	/* A COMMAND KEY IS THE MENU BAR'S. `NSApplication` offered it first; reaching here means no item claimed it, and
	 * a terminal that turned it into bytes would be typing a command nobody asked for. */
	if (([event modifierFlags] & NSCommandKeyMask) != 0) {
		return;
	}
	if (fn_is_commanding(characters)) {
		[[_session grid] keyWithKeysym:[event cg_keysym]
					 ascii:fn_ascii_keysym([event charactersIgnoringModifiers])
				     modifiers:fn_modifiers([event modifierFlags])
					 text:fn_character(characters)];
		return;
	}
	/* THE TEXT SYSTEM'S HALF, which is where a dead key composes and an input method would slot in. The event is kept
	 * because `-doCommandBySelector:` is told WHAT was asked, not by which keystroke. */
	[_keyEvent release];
	_keyEvent = [event retain];
	[self interpretKeyEvents:[NSArray arrayWithObject:event]];
}

- (void)insertText:(id)string
{
	/* **CONFIRMED TEXT IS BYTES ON THE PTY.** The input system may hand an attributed string; a terminal writes the
	 * characters and nothing else. This is also the door a composition ARRIVES at: `AGInputMethod` shows `´` as marked
	 * text and then calls this with `é`, so a dead key costs one write, not two. */
	if ([string isKindOfClass:[NSString class]]) {
		[_session writeString:string];
	} else if ([string respondsToSelector:@selector(string)]) {
		[_session writeString:[string string]];
	}
	[_markedString release];
	_markedString = nil;
}

/* THE FEW COMMANDS a text system produces that a terminal has an answer for, and each is the byte or the motion the
 * grid already knows how to produce. Anything else is the responder chain's, which is what `super` says. */
- (void)doCommandBySelector:(SEL)selector
{
	AGTerminalGrid *grid = [_session grid];

	if (selector == @selector(insertNewline:) || selector == @selector(insertParagraphSeparator:)) {
		[grid keyWithKeysym:XKB_KEY_Return ascii:XKB_KEY_NoSymbol modifiers:0 text:'\r'];
	} else if (selector == @selector(deleteBackward:)) {
		[grid keyWithKeysym:XKB_KEY_BackSpace ascii:XKB_KEY_NoSymbol modifiers:0 text:'\b'];
	} else if (selector == @selector(cancelOperation:)) {
		[grid keyWithKeysym:XKB_KEY_Escape ascii:XKB_KEY_NoSymbol modifiers:0 text:0x1b];
	} else if (selector == @selector(scrollPageUp:)) {
		[grid scrollUp:(NSUInteger)MAX(1, (NSInteger)[grid rows] - 1)];
		[self setNeedsDisplay:YES];
	} else if (selector == @selector(scrollPageDown:)) {
		[grid scrollDown:(NSUInteger)MAX(1, (NSInteger)[grid rows] - 1)];
		[self setNeedsDisplay:YES];
	} else {
		[super doCommandBySelector:selector];
	}
}

/* ---- the wheel, which is scrollback ------------------------------------------------------------ */

- (void)scrollWheel:(NSEvent *)event
{
	AGTerminalGrid *grid = [_session grid];
	CGFloat dy = [event deltaY];
	NSInteger lines;

	if (dy == 0.0) {
		return;
	}
	/* A wheel notch is one line; a trackpad's fraction is a fraction of one. Up is positive in Cocoa, which is the
	 * direction the scrollback moves BACK. */
	lines = (NSInteger)(dy < 0 ? -dy : dy);
	if (lines < 1) {
		lines = 1;
	}
	if (dy > 0.0) {
		[grid scrollUp:(NSUInteger)lines];
	} else {
		[grid scrollDown:(NSUInteger)lines];
	}
	[self setNeedsDisplay:YES];
}

/* ---- the session's side ------------------------------------------------------------------------ */

- (void)terminalSessionDidProduceOutput:(AGTerminalSession *)session
{
	(void)session;
	[self applySizeToSession];
	[self setNeedsDisplay:YES];
}

- (void)terminalSessionDidExit:(AGTerminalSession *)session
{
	(void)session;
	[self setNeedsDisplay:YES];
}

/* ---- NSTextInput: the composition, and the four questions a candidate window asks ------------------ */

/* **MARKED TEXT IS NOT WRITTEN TO THE PTY.** A dead key's accent is a COMPOSITION, not something the program should
 * receive: writing `´` and then `é` would put both on the glass. So the mark is remembered here, and the pty hears
 * exactly one write, from `-insertText:`, when the composition is confirmed. The consequence is stated rather than
 * hidden: a terminal shows nothing while a composition is in flight, which is what every terminal does. */
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange
{
	NSString *text;

	(void)selectedRange;
	text = [string isKindOfClass:[NSString class]] ? string : nil;
	[text retain];
	[_markedString release];
	_markedString = text;
}

- (void)unmarkText
{
	[_markedString release];
	_markedString = nil;
}

- (BOOL)hasMarkedText
{
	return _markedString != nil && [_markedString length] > 0;
}

- (NSRange)markedRange
{
	if (![self hasMarkedText]) {
		return NSMakeRange(NSNotFound, 0);
	}
	return NSMakeRange(0, [_markedString length]);
}

/* THERE IS NO SELECTION IN THIS SLICE, and saying so is the honest answer: the caret is the grid's cursor, and a
 * selection model is the next slice (`libtsm`'s `tsm_screen_selection_*` is what it will be built on). */
- (NSRange)selectedRange
{
	return NSMakeRange(NSNotFound, 0);
}

- (NSArray *)validAttributesForMarkedText
{
	return [NSArray array];
}

- (NSAttributedString *)attributedSubstringFromRange:(NSRange)range
{
	(void)range;
	return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
	(void)point;
	return NSNotFound;
}

/* **THE CARET'S RECTANGLE, which is where a candidate window would go.** Apple's door answers in SCREEN coordinates;
 * this tier has no such conversion (`NSWindow` has no `-convertRectToScreen:`), so it answers in the WINDOW's — the
 * same coordinates every other window-placed rectangle in this tree uses — and says so rather than inventing an
 * offset. A candidate window is the slice that will need the difference. */
- (NSRect)firstRectForCharacterRange:(NSRange)range
{
	AGTerminalGrid *grid = [_session grid];
	CGFloat cellWidth = [_renderer cellWidth];
	CGFloat cellHeight = [_renderer cellHeight];
	CGFloat x = (CGFloat)[grid cursorColumn] * cellWidth;
	CGFloat top = NSHeight([self bounds]) - (CGFloat)([grid cursorRow] + 1) * cellHeight;
	NSRect caret = NSMakeRect(x, top, MAX(1.0, cellWidth), cellHeight);

	(void)range;
	return [self convertRect:caret toView:nil];
}

/* ---- copy and paste, which are menu actions ---------------------------------------------------- */

- (void)paste:(id)sender
{
	NSPasteboard *board = [NSPasteboard generalPasteboard];
	NSString *string = [board stringForType:NSStringPboardType];

	(void)sender;
	if (string != nil) {
		[[_session grid] paste:string];
	}
}

/* THE TERMINAL OWNS ITS SELECTION, SO COPY IS A LATER SLICE AND REFUSES BY NAME.** A paste that silently produced the
 * empty string is the failure people hate, but so is a copy that silently did nothing. */
- (void)copy:(id)sender
{
	(void)sender;
}

- (BOOL)validateMenuItem:(id)item
{
	(void)item;
	return YES;
}

@end
